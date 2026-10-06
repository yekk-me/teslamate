defmodule TeslaApi.Stream do
  use WebSockex

  require Logger
  alias TeslaApi.Auth
  alias __MODULE__.Data

  defmodule State do
    defstruct auth: nil,
              vehicle_id: nil,
              tenant_id: nil,
              client_errors: 0,
              retry_at: nil,
              subscribe_timer: nil,
              timer: nil,
              receiver: &IO.inspect/1,
              last_data: nil,
              timeouts: 0,
              disconnects: 0
  end

  @columns ~w(speed odometer soc elevation est_heading est_lat est_lng power shift_state range
              est_range heading)a

  @cacerts CAStore.file_path()
           |> File.read!()
           |> :public_key.pem_decode()
           |> Enum.map(fn {_, cert, _} -> cert end)

  def start_link(args) do
    state = %State{
      receiver: Keyword.get(args, :receiver, &Logger.debug(inspect(&1))),
      vehicle_id: Keyword.fetch!(args, :vehicle_id),
      tenant_id: Keyword.get(args, :tenant_id),
      auth: Keyword.fetch!(args, :auth)
    }

    endpoint_url =
      case Auth.region(state.auth) do
        :chinese ->
          System.get_env("TESLA_WSS_HOST", "wss://streaming.vn.cloud.tesla.cn") <>
            "/streaming/" <>
            System.get_env("TOKEN", "")

        _global ->
          System.get_env("TESLA_WSS_HOST", "wss://streaming.vn.teslamotors.com") <>
            "/streaming/" <>
            System.get_env("TOKEN", "")
      end

    WebSockex.start_link(endpoint_url, __MODULE__, state,
      socket_connect_timeout: :timer.seconds(15),
      socket_recv_timeout: :timer.seconds(30),
      name: :"stream_#{state.vehicle_id}",
      cacerts: @cacerts,
      insecure: System.get_env("TESLA_WSS_TLS_ACCEPT_INVALID_CERTS", "") == "true",
      async: true
    )
  end

  def disconnect(pid) do
    WebSockex.cast(pid, :disconnect)
  end

  @impl true
  def handle_cast(:disconnect, %State{vehicle_id: vid} = state) do
    send(self(), :exit)
    {:reply, frame!(%{msg_type: "data:unsubscribe", tag: "#{vid}"}), state}
  end

  # The server greets every connection with control:hello, and each frame
  # re-arms `timer` as the receive timeout. A pending subscription must
  # therefore never live in `timer`: the greeting would cancel it and the
  # stream would stay connected without ever subscribing. Without a cooldown
  # subscribe right away (as before); during one, keep the delayed
  # subscription in its own timer.
  @impl true
  def handle_connect(_conn, state) do
    Logger.debug("Connection established")
    cancel_timer(state.subscribe_timer)

    case cooldown_ms(state) do
      0 ->
        send(self(), :subscribe)
        {:ok, %State{state | subscribe_timer: nil}}

      delay ->
        timer = Process.send_after(self(), :subscribe, delay)
        {:ok, %State{state | subscribe_timer: timer}}
    end
  end

  @impl true
  def handle_info(:subscribe, %State{retry_at: deadline} = state) when is_integer(deadline) do
    case cooldown_ms(state) do
      0 ->
        handle_info(:subscribe, %State{state | retry_at: nil})

      remaining ->
        cancel_timer(state.subscribe_timer)
        timer = Process.send_after(self(), :subscribe, remaining)
        {:ok, %State{state | subscribe_timer: timer}}
    end
  end

  def handle_info(:subscribe, %State{auth: %Auth{token: token}, vehicle_id: vid} = state) do
    Logger.debug("Subscribing …")

    cancel_timer(state.timer)
    ms = exp_backoff_ms(state.timeouts, min_seconds: 10, max_seconds: 30)
    timer = Process.send_after(self(), :timeout, ms)

    connect_message = %{
      msg_type: "data:subscribe_oauth",
      token: token,
      value: Enum.join(@columns, ","),
      tag: "#{vid}"
    }

    {:reply, frame!(connect_message),
     %State{state | timer: timer, subscribe_timer: nil, retry_at: nil}}
  end

  def handle_info(:timeout, %State{timeouts: t, receiver: receiver} = state) do
    Logger.debug("Stream.Timeout / #{inspect(t)}")

    if match?(%State{last_data: %Data{}}, state) and rem(t, 10) == 4 do
      receiver.(:inactive)
    end

    {:close, %State{state | timeouts: t + 1}}
  end

  def handle_info({:ssl, _, _} = msg, state) do
    Logger.warning("Received unexpected message: #{inspect(msg)}")
    {:ok, state}
  end

  def handle_info(:exit, _state) do
    exit(:normal)
  end

  @impl true
  def handle_frame({_type, msg}, %State{vehicle_id: vid} = state) do
    tag = to_string(vid)

    state =
      if state.retry_at do
        state
      else
        cancel_timer(state.timer)
        timer = Process.send_after(self(), :timeout, :timer.seconds(30))
        %State{state | timer: timer}
      end

    case Jason.decode(msg) do
      {:ok, %{"msg_type" => "control:hello", "connection_timeout" => t}} ->
        Logger.debug("control:hello – #{t}")
        {:ok, state}

      {:ok, %{"msg_type" => "data:update", "tag" => ^tag, "value" => data}}
      when is_binary(data) ->
        data =
          Enum.zip([:time | @columns], String.split(data, ","))
          |> Enum.into(%{})
          |> Data.into!()

        state.receiver.(data)

        {:ok,
         %State{
           state
           | last_data: data,
             timeouts: 0,
             disconnects: 0,
             client_errors: 0,
             retry_at: nil
         }}

      {:ok, %{"msg_type" => "data:error", "tag" => ^tag, "error_type" => "vehicle_disconnected"}} ->
        case state.disconnects do
          d when d != 0 and rem(d, 10) == 0 ->
            Logger.warning("Too many disconnects from streaming API")

            cancel_timer(state.timer)
            state.receiver.(:too_many_disconnects)

            {:ok, %State{state | disconnects: d + 1}}

          d ->
            ms =
              case state do
                %State{last_data: %Data{shift_state: s}} when s in ~w(P D N R) ->
                  exp_backoff_ms(d, base: 1.3, max_seconds: 8)

                %State{} ->
                  exp_backoff_ms(d, min_seconds: 15, max_seconds: 30)
              end

            cancel_timer(state.timer)
            timer = Process.send_after(self(), :subscribe, ms)

            {:ok, %State{state | timer: timer, disconnects: d + 1}}
        end

      {:ok,
       %{"msg_type" => "data:error", "tag" => ^tag, "error_type" => "vehicle_error", "value" => v}} ->
        case v do
          "Vehicle is offline" ->
            Logger.info("Streaming API: Vehicle offline")
            state.receiver.(:vehicle_offline)

          _ ->
            Logger.error("Vehicle Error: #{v}")
        end

        {:ok, state}

      {:ok, %{"msg_type" => "data:error", "tag" => ^tag, "error_type" => "client_error"} = msg} ->
        case msg do
          %{"value" => "owner_api error:" <> _ = error} ->
            failures = min(state.client_errors + 1, 5)
            delay = min(30_000 * Integer.pow(2, failures - 1), 300_000)

            status =
              case Regex.run(~r/HTTP status: (\d{3})\b/, error) do
                [_, code] -> code
                _ -> "unknown"
              end

            Logger.warning(
              "Streaming API owner error: status=#{status} retry_in_ms=#{delay}",
              tenant_id: state.tenant_id,
              vehicle_id: if(is_integer(vid), do: vid, else: nil)
            )

            cancel_timer(state.timer)
            cancel_timer(state.subscribe_timer)

            {:close,
             %State{
               state
               | timer: nil,
                 subscribe_timer: nil,
                 client_errors: failures,
                 retry_at: now_ms() + delay
             }}

          %{"value" => "Can't validate token" <> _} ->
            Logger.warning("Streaming API: Tokens expired")
            state.receiver.(:tokens_expired)
            {:ok, state}

          _ ->
            raise "Client Error: #{inspect(msg)}"
        end

      {:ok, %{"msg_type" => "data:error", "tag" => ^tag, "error_type" => type, "value" => v}} ->
        Logger.error("Error #{inspect(type)}: #{v}")
        {:ok, state}

      {:ok, msg} ->
        Logger.warning("Unknown Message: #{inspect(msg, pretty: true)}")
        {:ok, state}

      {:error, reason} ->
        Logger.error("Invalid data frame: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_disconnect(%{reason: reason, attempt_number: n}, state) when is_number(n) do
    cancel_timer(state.timer)
    cancel_timer(state.subscribe_timer)
    state = %State{state | timer: nil, subscribe_timer: nil}

    case reason do
      {:local, :normal} ->
        Logger.debug(
          "Connection was closed (a:#{n}|t:#{state.timeouts}|d:#{state.disconnects}). Reconnecting …"
        )

        {:reconnect, state}

      {:remote, :closed} ->
        Logger.warning("WebSocket disconnected. Reconnecting …")

        n
        |> exp_backoff_ms(max_seconds: 10)
        |> Process.sleep()

        {:reconnect, %State{state | last_data: nil}}

      %WebSockex.ConnError{} = e ->
        Logger.warning("Disconnected! #{Exception.message(e)} | #{n}")

        n
        |> exp_backoff_ms(min_seconds: 1)
        |> Process.sleep()

        {:reconnect, state}

      %WebSockex.RequestError{} = e ->
        Logger.warning("Disconnected! #{Exception.message(e)} | #{n}")

        n
        |> exp_backoff_ms(min_seconds: 1)
        |> Process.sleep()

        {:reconnect, state}
    end
  end

  @impl true
  def terminate(:normal, _state), do: :ok

  def terminate(reason, _state) do
    # https://github.com/Azolo/websockex/issues/51
    with {exception, stacktrace} <- reason, true <- is_exception(exception) do
      Logger.error(fn -> Exception.format(:error, exception, stacktrace) end)
    else
      _ -> Logger.error("Terminating: #{inspect(reason)}")
    end

    :ok
  end

  ## Private

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp cooldown_ms(%State{retry_at: nil}), do: 0
  defp cooldown_ms(%State{retry_at: deadline}), do: max(deadline - now_ms(), 0)

  defp frame!(data) when is_map(data), do: {:text, Jason.encode!(data)}

  defp exp_backoff_ms(n, opts) when is_number(n) and 0 <= n do
    base = Keyword.get(opts, :base, 2)
    min = Keyword.get(opts, :min_seconds, 0)
    max = Keyword.get(opts, :max_seconds, 30)

    :math.pow(base, n) |> min(max) |> max(min) |> round() |> :timer.seconds()
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
end
