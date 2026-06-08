defmodule TeslaMate.MultiTenant.MqttTest do
  use ExUnit.Case, async: false

  alias TeslaMate.MultiTenant.Tenant
  alias TeslaMate.MultiTenant.TrafficLimiter
  alias TeslaMate.Mqtt.Publisher

  test "pubsub supports tenant-scoped names and injected dependencies" do
    publisher = start_supervised!({PublisherMock, pid: self(), name: :tenant_mqtt_publisher})

    start_supervised!(
      {TeslaMate.Mqtt.PubSub,
       name: :tenant_mqtt_pubsub,
       namespace: "tenant-a",
       car_ids: [1],
       vehicles: {TenantVehiclesMock, self()},
       publisher: {PublisherMock, publisher}}
    )

    assert_receive {TenantVehiclesMock, {:subscribe_to_summary, 1}}
    assert_receive {PublisherMock, {:publish, "teslamate/tenant-a/cars/1/healthy", "", _opts}}
  end

  test "pubsub uses tenant vehicle summaries when explicit car ids are omitted" do
    publisher =
      start_supervised!({PublisherMock, pid: self(), name: :tenant_mqtt_publisher_from_list})

    start_supervised!(
      {TeslaMate.Mqtt.PubSub,
       name: :tenant_mqtt_pubsub_from_list,
       namespace: "tenant-list",
       vehicles: {TenantVehiclesListMock, self()},
       publisher: {PublisherMock, publisher}}
    )

    assert_receive {TenantVehiclesListMock, :list}
    assert_receive {TenantVehiclesListMock, {:subscribe_to_summary, 42}}
    assert_receive {PublisherMock, {:publish, "teslamate/tenant-list/cars/42/healthy", "", _opts}}
  end

  test "tenant publisher denies publishes after mqtt quota is exhausted" do
    start_supervised!({Registry, keys: :unique, name: TeslaMate.MultiTenant.Registry})

    {:ok, tenant} =
      Tenant.new(%{
        id: "tenant-mqtt-limited",
        database: %{host: "localhost", name: "db", username: "tm", password: "secret"},
        limits: %{mqtt_publishes_per_minute: 0}
      })

    start_supervised!({TrafficLimiter, tenant: tenant})

    start_supervised!(
      {Publisher, client_id: "client", name: :tenant_limited_publisher, tenant_id: tenant.id}
    )

    assert {:error, :rate_limited} =
             Publisher.publish(
               :tenant_limited_publisher,
               "teslamate/tenant/cars/1/state",
               "online",
               []
             )
  end
end

defmodule TenantVehiclesMock do
  def subscribe_to_summary(pid, car_id) do
    send(pid, {__MODULE__, {:subscribe_to_summary, car_id}})
    :ok
  end
end

defmodule TenantVehiclesListMock do
  def list(pid) do
    send(pid, {__MODULE__, :list})
    [%TeslaMate.Vehicles.Vehicle.Summary{car: %TeslaMate.Log.Car{id: 42}}]
  end

  def subscribe_to_summary(pid, car_id) do
    send(pid, {__MODULE__, {:subscribe_to_summary, car_id}})
    :ok
  end
end

defmodule PublisherMock do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def publish(pid, topic, msg, opts), do: GenServer.call(pid, {:publish, topic, msg, opts})

  @impl true
  def init(opts), do: {:ok, %{pid: Keyword.fetch!(opts, :pid)}}

  @impl true
  def handle_call({:publish, _topic, _msg, _opts} = event, _from, state) do
    send(state.pid, {__MODULE__, event})
    {:reply, :ok, state}
  end
end
