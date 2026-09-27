defmodule TeslaApi.StreamTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias TeslaApi.Stream
  alias TeslaApi.Stream.State

  defp state do
    %State{vehicle_id: 123, tenant_id: "tenant-test", receiver: fn _ -> :ok end}
  end

  defp owner_error(state, status \\ 403) do
    frame =
      Jason.encode!(%{
        msg_type: "data:error",
        tag: "123",
        error_type: "client_error",
        value: "owner_api error: Got HTTP status: #{status} Forbidden. secret-response-token"
      })

    {:close, failed} = Stream.handle_frame({:text, frame}, state)
    failed
  end

  @tag :capture_log
  test "repeated owner errors back off across successful websocket handshakes" do
    Enum.reduce([30_000, 60_000, 120_000, 240_000, 300_000, 300_000], state(), fn delay, state ->
      failed = owner_error(state)
      assert (failed.retry_at - System.monotonic_time(:millisecond)) in (delay - 1000)..delay

      {:reconnect, failed} =
        Stream.handle_disconnect(%{reason: {:local, :normal}, attempt_number: 1}, failed)

      {:ok, waiting} = Stream.handle_connect(nil, failed)
      assert Process.read_timer(waiting.timer) in (delay - 1000)..delay
      refute_receive :subscribe, 10
      Process.cancel_timer(waiting.timer)
      waiting
    end)
  end

  @tag :capture_log
  test "control hello does not replace cooldown with a 30 second timeout" do
    waiting = %{owner_error(state()) | retry_at: System.monotonic_time(:millisecond) + 300_000}
    {:ok, waiting} = Stream.handle_connect(nil, waiting)
    hello = Jason.encode!(%{msg_type: "control:hello", connection_timeout: 30})
    {:ok, next} = Stream.handle_frame({:text, hello}, waiting)
    assert next.timer == waiting.timer
    assert Process.read_timer(next.timer) > 290_000
    Process.cancel_timer(next.timer)
  end

  @tag :capture_log
  test "subscription leaves cooldown and valid data resets consecutive failures" do
    failed = %{
      owner_error(state())
      | auth: %TeslaApi.Auth{token: "test-token"},
        retry_at: System.monotonic_time(:millisecond) - 1
    }

    {:reply, {:text, subscription}, subscribed} = Stream.handle_info(:subscribe, failed)
    assert Jason.decode!(subscription)["msg_type"] == "data:subscribe_oauth"
    assert subscribed.retry_at == nil
    assert subscribed.client_errors == 1

    frame =
      Jason.encode!(%{
        msg_type: "data:update",
        tag: "123",
        value: "1600000000000,0,1,50,0,0,0,0,0,P,100,100,0"
      })

    {:ok, recovered} = Stream.handle_frame({:text, frame}, subscribed)
    assert recovered.client_errors == 0
    assert recovered.retry_at == nil
    Process.cancel_timer(recovered.timer)
    again = owner_error(recovered)
    assert (again.retry_at - System.monotonic_time(:millisecond)) in 29_000..30_000
  end

  test "owner error logs identify tenant and numeric vehicle without raw response" do
    log =
      capture_log([format: "$metadata$message", metadata: [:tenant_id, :vehicle_id]], fn ->
        owner_error(state())
      end)

    assert log =~ "tenant_id=tenant-test"
    assert log =~ "vehicle_id=123"
    assert log =~ "status=403"
    refute log =~ "secret-response-token"
  end

  @tag :capture_log
  test "manual disconnect remains responsive during cooldown" do
    {:ok, waiting} = Stream.handle_connect(nil, owner_error(state()))
    assert {:reply, {:text, _}, _} = Stream.handle_cast(:disconnect, waiting)
    assert_receive :exit
    Process.cancel_timer(waiting.timer)
  end

  test "normal connect subscribes immediately" do
    {:ok, connected} = Stream.handle_connect(nil, state())
    assert_receive :subscribe
    assert connected.client_errors == 0
  end

  @tag :capture_log
  test "stale subscribe messages cannot bypass cooldown" do
    failed = owner_error(state())
    assert {:ok, waiting} = Stream.handle_info(:subscribe, failed)
    assert Process.read_timer(waiting.timer) > 29_000
    Process.cancel_timer(waiting.timer)
  end
end
