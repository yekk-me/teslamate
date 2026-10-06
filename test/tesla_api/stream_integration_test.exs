defmodule TeslaApi.StreamIntegrationTest do
  # Drives the real WebSocket client against a local server that speaks the
  # streaming protocol, so connect -> hello -> subscribe -> data is exercised
  # end to end instead of callback by callback.
  use ExUnit.Case, async: false

  alias TeslaApi.Stream

  defmodule FakeStreamingSocket do
    @behaviour :cowboy_websocket

    @impl true
    def init(req, opts), do: {:cowboy_websocket, req, opts, %{idle_timeout: 60_000}}

    @impl true
    def websocket_init(%{test: test} = state) do
      send(test, {:fake_stream, :connected})
      hello = Jason.encode!(%{msg_type: "control:hello", connection_timeout: 30_000})
      {[{:text, hello}], state}
    end

    @impl true
    def websocket_handle({:text, raw}, state) do
      case Jason.decode!(raw) do
        %{"msg_type" => "data:subscribe_oauth", "tag" => tag} ->
          send(state.test, {:fake_stream, :subscribed, tag})
          Process.send_after(self(), :push, 50)
          {[], Map.put(state, :tag, tag)}

        _other ->
          {[], state}
      end
    end

    def websocket_handle(_frame, state), do: {[], state}

    @impl true
    def websocket_info(:push, %{tag: tag} = state) do
      now = System.system_time(:millisecond)
      value = "#{now},42,1000.5,80,10,90,30.1,120.2,15,D,300,290,90"
      update = Jason.encode!(%{msg_type: "data:update", tag: tag, value: value})
      Process.send_after(self(), :push, 50)
      {[{:text, update}], state}
    end

    def websocket_info(_msg, state), do: {[], state}
  end

  defp start_server(scheme) do
    test = self()
    ref = :"fake_stream_#{System.unique_integer([:positive])}"
    dispatch = :cowboy_router.compile([{:_, [{:_, FakeStreamingSocket, %{test: test}}]}])
    opts = %{env: %{dispatch: dispatch}}

    {:ok, _} =
      case scheme do
        "ws" ->
          :cowboy.start_clear(ref, [port: 0], opts)

        "wss" ->
          dir = cert_dir()

          tls = [
            port: 0,
            certfile: Path.join(dir, "cert.pem"),
            keyfile: Path.join(dir, "key.pem")
          ]

          :cowboy.start_tls(ref, tls, opts)
      end

    previous =
      {System.get_env("TESLA_WSS_HOST"), System.get_env("TESLA_WSS_TLS_ACCEPT_INVALID_CERTS")}

    System.put_env("TESLA_WSS_HOST", "#{scheme}://127.0.0.1:#{:ranch.get_port(ref)}")
    System.put_env("TESLA_WSS_TLS_ACCEPT_INVALID_CERTS", "true")

    on_exit(fn ->
      :cowboy.stop_listener(ref)
      {host, insecure} = previous

      if host,
        do: System.put_env("TESLA_WSS_HOST", host),
        else: System.delete_env("TESLA_WSS_HOST")

      if insecure,
        do: System.put_env("TESLA_WSS_TLS_ACCEPT_INVALID_CERTS", insecure),
        else: System.delete_env("TESLA_WSS_TLS_ACCEPT_INVALID_CERTS")
    end)
  end

  # The server greets immediately, so a regression where the greeting cancels
  # the subscription is a race; reconnect repeatedly to make it visible.
  for scheme <- ["ws", "wss"] do
    @scheme scheme
    test "fresh #{scheme} streams subscribe and deliver vehicle data" do
      start_server(@scheme)
      for _ <- 1..10, do: assert_streams_data()
    end
  end

  # A throwaway self-signed certificate; the client accepts it through
  # TESLA_WSS_TLS_ACCEPT_INVALID_CERTS, exactly like a test deployment would.
  defp cert_dir do
    case System.get_env("STREAM_TEST_CERT_DIR") do
      nil ->
        dir =
          Path.join(System.tmp_dir!(), "stream_test_cert_#{System.unique_integer([:positive])}")

        File.mkdir_p!(dir)

        {_, 0} =
          System.cmd(
            "openssl",
            [
              "req",
              "-x509",
              "-newkey",
              "rsa:2048",
              "-nodes",
              "-days",
              "1",
              "-subj",
              "/CN=127.0.0.1",
              "-keyout",
              Path.join(dir, "key.pem"),
              "-out",
              Path.join(dir, "cert.pem")
            ],
            stderr_to_stdout: true
          )

        on_exit(fn -> File.rm_rf!(dir) end)
        dir

      dir ->
        dir
    end
  end

  defp assert_streams_data do
    test = self()

    {:ok, pid} =
      Stream.start_link(
        auth: %TeslaApi.Auth{token: "qts-integration-token"},
        vehicle_id: 4_242_424_242,
        tenant_id: "tenant-integration",
        receiver: fn data -> send(test, {:stream_data, data}) end
      )

    assert_receive {:fake_stream, :connected}, 5_000
    assert_receive {:fake_stream, :subscribed, "4242424242"}, 5_000

    for _ <- 1..3 do
      assert_receive {:stream_data, %Stream.Data{speed: 42, shift_state: "D"}}, 2_000
    end

    ref = Process.monitor(pid)
    Stream.disconnect(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end
end
