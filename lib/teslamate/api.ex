defmodule TeslaMate.Api do
  use GenServer

  require Logger

  alias TeslaMate.Auth.Tokens
  alias TeslaMate.{Vehicles, Convert, Mqtt}
  alias TeslaApi.Auth

  alias Finch.Response

  import Core.Dependency, only: [call: 3, call: 2]

  defmodule State do
    defstruct name: nil, deps: %{}, refresh_timer: nil, auth_table: nil, tenant_id: nil
  end

  @timeout :timer.minutes(2)
  @name __MODULE__

  # API

  def start_link(opts) do
    opts = Keyword.put_new(opts, :name, @name)
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  ## State

  def list_vehicles(name \\ @name) do
    tenant_id = tenant_id_for(name)

    with :ok <- allow_tesla_api(tenant_id),
         {:ok, auth} <- fetch_auth(name) do
      TeslaApi.Vehicle.list(auth)
      |> handle_result(auth, name, tenant_id)
    end
  end

  def get_vehicle(name \\ @name, id) do
    tenant_id = tenant_id_for(name)

    with :ok <- allow_tesla_api(tenant_id),
         {:ok, auth} <- fetch_auth(name) do
      TeslaApi.Vehicle.get(auth, id)
      |> handle_result(auth, name, tenant_id)
    end
  end

  def get_vehicle_with_state(name \\ @name, id) do
    tenant_id = tenant_id_for(name)

    with :ok <- allow_tesla_api(tenant_id),
         {:ok, auth} <- fetch_auth(name) do
      TeslaApi.Vehicle.get_with_state(auth, id)
      |> handle_result(auth, name, tenant_id)
    end
  end

  def stream(name \\ @name, vid, receiver) do
    tenant_id = tenant_id_for(name)

    with :ok <- allow_tesla_api(tenant_id),
         {:ok, %Auth{} = auth} <- fetch_auth(name) do
      TeslaApi.Stream.start_link(auth: auth, vehicle_id: vid, receiver: receiver)
    end
  end

  ## Internals

  def signed_in?(name \\ @name) do
    case fetch_auth(name) do
      {:error, :not_signed_in} -> false
      {:ok, _} -> true
    end
  end

  def sign_in(name \\ @name, args)

  def sign_in(name, %Tokens{} = tokens) do
    case fetch_auth(name) do
      {:error, :not_signed_in} -> GenServer.call(name, {:sign_in, [tokens]}, @timeout)
      {:ok, %Auth{}} -> {:error, :already_signed_in}
    end
  end

  def sign_in(name, {email, password}) do
    case fetch_auth(name) do
      {:error, :not_signed_in} -> GenServer.call(name, {:sign_in, [email, password]}, @timeout)
      {:ok, %Auth{}} -> {:error, :already_signed_in}
    end
  end

  def sign_out(name \\ @name) do
    GenServer.call(name, :sign_out)
  end

  # Callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    tenant_id = Keyword.get(opts, :tenant_id)

    if is_binary(tenant_id) do
      TeslaMate.MultiTenant.TenantContext.put(tenant_id)
    end

    deps = %{
      auth: Keyword.get(opts, :auth, TeslaMate.Auth),
      vehicles: Keyword.get(opts, :vehicles, Vehicles)
    }

    :ok =
      :fuse.install(
        fuse_name(name),
        {{:standard, 5, :timer.minutes(10)}, {:reset, :timer.hours(9999)}}
      )

    auth_table = :ets.new(:auth, [:set, :public, read_concurrency: true])
    state = %State{name: name, deps: deps, auth_table: auth_table, tenant_id: tenant_id}

    state =
      case call(deps.auth, :get_tokens) do
        %Tokens{access: at, refresh: rt} when is_binary(at) and is_binary(rt) ->
          restored_tokens = %Auth{token: at, refresh_token: rt, expires_in: 10 * 60}

          {:ok, state} =
            case refresh_tokens(restored_tokens) do
              {:ok, refreshed_tokens} ->
                :ok = call(deps.auth, :save, [refreshed_tokens])
                true = insert_auth(state, refreshed_tokens)
                schedule_refresh(refreshed_tokens, state)

              {:error, reason} ->
                Logger.warning("Token refresh failed: #{inspect(reason, pretty: true)}")
                true = insert_auth(state, restored_tokens)
                schedule_refresh(restored_tokens, state)
            end

          state

        %Tokens{access: :error, refresh: :error} ->
          Logger.warning("Could not decrypt API tokens!")
          state

        _ ->
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:fetch_auth, _from, %State{} = state) do
    {:reply, fetch_auth(state), state}
  end

  def handle_call(:tenant_id, _from, %State{} = state) do
    {:reply, state.tenant_id, state}
  end

  def handle_call(:sign_out, _from, %State{} = state) do
    true = :ets.delete(state.auth_table, :auth)
    {:reply, :ok, state}
  rescue
    _ in ArgumentError -> {:reply, {:error, :not_signed_in}, state}
  end

  def handle_call(:clear_auth, _from, %State{} = state) do
    true = :ets.delete(state.auth_table, :auth)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:sign_in, args}, _, %State{} = state) do
    case args do
      [args, callback] when is_function(callback) -> apply(callback, args)
      [%Tokens{} = t] -> Auth.refresh(%Auth{token: t.access, refresh_token: t.refresh})
    end
    |> case do
      {:ok, %Auth{} = auth} ->
        true = insert_auth(state, auth)
        :ok = call(state.deps.auth, :save, [auth])
        :ok = call(state.deps.vehicles, :restart)
        :ok = restart_mqtt_pubsub(state.tenant_id)
        {:ok, state} = schedule_refresh(auth, state)
        :ok = :fuse.reset(fuse_name(state.name))

        {:reply, :ok, state}

      {:ok, {:captcha, captcha, callback}} ->
        wrapped_callback = fn captcha_code ->
          GenServer.call(state.name, {:sign_in, [[captcha_code], callback]}, @timeout)
        end

        {:reply, {:ok, {:captcha, captcha, wrapped_callback}}, state}

      {:ok, {:mfa, devices, callback}} ->
        wrapped_callback = fn device_id, mfa_passcode ->
          GenServer.call(state.name, {:sign_in, [[device_id, mfa_passcode], callback]}, @timeout)
        end

        {:reply, {:ok, {:mfa, devices, wrapped_callback}}, state}

      {:error, %TeslaApi.Error{} = e} ->
        {:reply, {:error, e}, state}
    end
  end

  @impl true
  def handle_info(:refresh_auth, %State{name: name} = state) do
    case fetch_auth(state) do
      {:ok, tokens} ->
        Logger.info("Refreshing access token ...")

        case Auth.refresh(tokens) do
          {:ok, refreshed_tokens} ->
            true = insert_auth(state, refreshed_tokens)
            :ok = call(state.deps.auth, :save, [refreshed_tokens])
            {:ok, state} = schedule_refresh(refreshed_tokens, state)
            :ok = :fuse.reset(fuse_name(name))
            {:noreply, state}

          {:error, reason} ->
            Logger.warning("Token refresh failed: #{inspect(reason, pretty: true)}")
            Logger.warning("Retrying in 5 minutes...")

            if is_reference(state.refresh_timer), do: Process.cancel_timer(state.refresh_timer)
            refresh_timer = Process.send_after(self(), :refresh_auth, :timer.minutes(5))

            {:noreply, %State{state | refresh_timer: refresh_timer}}
        end

      {:error, reason} ->
        Logger.warning("Cannot refresh access token: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.info("#{__MODULE__} / unhandled message: #{inspect(msg, pretty: true)}")
    {:noreply, state}
  end

  ## Private

  defp refresh_tokens(%Auth{} = tokens) do
    case Application.get_env(:teslamate, :disable_token_refresh, false) do
      true ->
        Logger.info("Token refresh is disabled")
        {:ok, tokens}

      false ->
        with {:ok, %Auth{} = refresh_tokens} <- Auth.refresh(tokens) do
          Logger.info("Refreshed api tokens")
          {:ok, refresh_tokens}
        end
    end
  end

  defp schedule_refresh(%Auth{} = auth, %State{} = state) do
    ms =
      auth.expires_in
      |> Kernel.*(0.75)
      |> round()
      |> :timer.seconds()

    duration =
      ms
      |> div(1000)
      |> Convert.sec_to_str()
      |> Enum.reject(&String.ends_with?(&1, "s"))
      |> Enum.join(" ")

    Logger.info("Scheduling token refresh in #{duration}")

    if is_reference(state.refresh_timer), do: Process.cancel_timer(state.refresh_timer)
    refresh_timer = Process.send_after(self(), :refresh_auth, ms)

    {:ok, %State{state | refresh_timer: refresh_timer}}
  end

  defp insert_auth(%State{auth_table: table}, %Auth{} = auth) do
    :ets.insert(table, auth: auth)
  end

  defp fetch_auth(%State{auth_table: table}) do
    case :ets.lookup(table, :auth) do
      [auth: %Auth{} = auth] -> {:ok, auth}
      [] -> {:error, :not_signed_in}
    end
  rescue
    _ in ArgumentError -> {:error, :not_signed_in}
  end

  defp fetch_auth(name), do: GenServer.call(name, :fetch_auth)

  defp handle_result(result, auth, name, tenant_id) do
    case result do
      {:error, %TeslaApi.Error{reason: :unauthorized}} ->
        :ok = :fuse.melt(fuse_name(name))

        case :fuse.ask(fuse_name(name), :sync) do
          :blown ->
            :ok = clear_auth(name)
            {:error, :not_signed_in}

          :ok ->
            send(name, :refresh_auth)
            {:error, :unauthorized}
        end

      {:error, %TeslaApi.Error{reason: reason, env: %Response{status: status, body: body}}} ->
        Logger.error("TeslaApi.Error / #{status} – #{inspect(body, pretty: true)}")
        {:error, reason}

      {:error, %TeslaApi.Error{reason: :too_many_request, message: retry_after}} ->
        Logger.warning("TeslaApi.Error / :too_many_request #{retry_after}")
        {:error, :too_many_request, retry_after}

      {:error, %TeslaApi.Error{reason: reason, message: msg}} ->
        if is_binary(msg) and msg != "", do: Logger.warning("TeslaApi.Error / #{msg}")
        {:error, reason}

      {:ok, vehicles} when is_list(vehicles) ->
        vehicles =
          vehicles
          |> Task.async_stream(&preload_vehicle(&1, auth, tenant_id), timeout: 32_500)
          |> Enum.map(fn {:ok, vehicle} -> vehicle end)

        {:ok, vehicles}

      {:ok, %TeslaApi.Vehicle{} = vehicle} ->
        {:ok, vehicle}
    end
  end

  defp preload_vehicle(%TeslaApi.Vehicle{state: "online", id: id} = vehicle, auth, tenant_id) do
    with :ok <- allow_tesla_api(tenant_id) do
      case TeslaApi.Vehicle.get_with_state(auth, id) do
        {:ok, %TeslaApi.Vehicle{} = vehicle} ->
          vehicle

        {:error, reason} ->
          Logger.warning("TeslaApi.Error / #{inspect(reason, pretty: true)}")
          vehicle
      end
    else
      {:error, :rate_limited} ->
        Logger.warning("Tesla API preload rate limited")
        vehicle
    end
  end

  defp preload_vehicle(%TeslaApi.Vehicle{} = vehicle, _auth, _tenant_id), do: vehicle

  defp clear_auth(name), do: GenServer.call(name, :clear_auth)

  defp tenant_id_for(@name), do: nil

  defp tenant_id_for(name) do
    GenServer.call(name, :tenant_id)
  catch
    :exit, _reason -> nil
  end

  defp allow_tesla_api(nil), do: :ok

  defp allow_tesla_api(tenant_id) do
    if TeslaMate.MultiTenant.TrafficLimiter.allow?(tenant_id, :tesla_api) do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp restart_mqtt_pubsub(nil), do: Mqtt.restart_pubsub()

  defp restart_mqtt_pubsub(tenant_id) do
    tenant_id
    |> TeslaMate.MultiTenant.TenantSupervisor.mqtt_name()
    |> Mqtt.restart_pubsub()
  end

  defp fuse_name(name), do: :"#{__MODULE__}.#{:erlang.phash2(name)}.unauthorized"
end
