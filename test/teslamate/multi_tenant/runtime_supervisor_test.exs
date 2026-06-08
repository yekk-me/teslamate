defmodule TeslaMate.MultiTenant.RuntimeSupervisorTest do
  use ExUnit.Case, async: false

  alias TeslaMate.MultiTenant.RuntimeSupervisor
  alias TeslaMate.MultiTenant.Tenant
  alias TeslaMate.MultiTenant.TrafficLimiter
  alias TeslaMate.MultiTenant.VehicleWorker

  setup do
    original = Application.get_env(:teslamate, TeslaMate.MultiTenant, [])

    Application.put_env(:teslamate, TeslaMate.MultiTenant,
      start_repo?: false,
      start_vehicle_workers?: true,
      vehicle_runtime: :placeholder,
      start_mqtt?: false
    )

    start_supervised!({Registry, keys: :unique, name: TeslaMate.MultiTenant.Registry})
    supervisor = start_supervised!({RuntimeSupervisor, name: __MODULE__.Runtime})

    on_exit(fn ->
      Application.put_env(:teslamate, TeslaMate.MultiTenant, original)
    end)

    %{supervisor: supervisor}
  end

  test "starts one tenant runtime per active tenant", %{supervisor: supervisor} do
    tenant_a = tenant("runtime-start-a", ["car-1", "car-2"])
    tenant_b = tenant("runtime-start-b", ["car-3"])

    assert :ok = RuntimeSupervisor.sync(supervisor, [tenant_a, tenant_b])

    assert %{"runtime-start-a" => _, "runtime-start-b" => _} =
             RuntimeSupervisor.running_tenants(supervisor)

    assert [{worker_pid, _}] =
             Registry.lookup(
               TeslaMate.MultiTenant.Registry,
               {:vehicle, "runtime-start-a", "car-1"}
             )

    assert %{
             tenant_id: "runtime-start-a",
             vehicle_id: "car-1",
             mqtt_namespace: "runtime-start-a"
           } = VehicleWorker.summary(worker_pid)
  end

  test "stops tenant runtime when assignment disappears", %{supervisor: supervisor} do
    tenant_a = tenant("runtime-stop-a", ["car-1"])
    tenant_b = tenant("runtime-stop-b", ["car-2"])

    assert :ok = RuntimeSupervisor.sync(supervisor, [tenant_a, tenant_b])

    assert %{"runtime-stop-a" => _, "runtime-stop-b" => _} =
             RuntimeSupervisor.running_tenants(supervisor)

    assert :ok = RuntimeSupervisor.sync(supervisor, [tenant_b])

    assert %{"runtime-stop-b" => _} = RuntimeSupervisor.running_tenants(supervisor)

    assert [] =
             Registry.lookup(
               TeslaMate.MultiTenant.Registry,
               {:vehicle, "runtime-stop-a", "car-1"}
             )
  end

  test "restarts tenant runtime when assignment changes", %{supervisor: supervisor} do
    tenant_v1 = tenant("runtime-reload", ["car-1"])
    tenant_v2 = tenant("runtime-reload", ["car-2"])

    assert :ok = RuntimeSupervisor.sync(supervisor, [tenant_v1])

    assert [{first_pid, _}] =
             Registry.lookup(TeslaMate.MultiTenant.Registry, {:tenant, "runtime-reload"})

    assert [{_, _}] =
             Registry.lookup(
               TeslaMate.MultiTenant.Registry,
               {:vehicle, "runtime-reload", "car-1"}
             )

    assert :ok = RuntimeSupervisor.sync(supervisor, [tenant_v2])

    assert [{second_pid, _}] =
             Registry.lookup(TeslaMate.MultiTenant.Registry, {:tenant, "runtime-reload"})

    refute first_pid == second_pid

    assert [] =
             Registry.lookup(
               TeslaMate.MultiTenant.Registry,
               {:vehicle, "runtime-reload", "car-1"}
             )

    assert [{_, _}] =
             Registry.lookup(
               TeslaMate.MultiTenant.Registry,
               {:vehicle, "runtime-reload", "car-2"}
             )
  end

  test "does not start tenants rejected by policy", %{supervisor: supervisor} do
    blocked =
      tenant("runtime-blocked", ["car-1"])
      |> put_in([Access.key!(:entitlements), "logging"], false)

    assert :ok = RuntimeSupervisor.sync(supervisor, [blocked])
    assert %{} = RuntimeSupervisor.running_tenants(supervisor)
  end

  test "starts tenant traffic limiter with configured quotas", %{supervisor: supervisor} do
    limited =
      tenant("runtime-limited", ["car-1"])
      |> put_in([Access.key!(:limits), Access.key!(:tesla_api_requests_per_minute)], 2)

    assert :ok = RuntimeSupervisor.sync(supervisor, [limited])

    assert true = TrafficLimiter.allow?("runtime-limited", :tesla_api)
    assert true = TrafficLimiter.allow?("runtime-limited", :tesla_api)
    refute TrafficLimiter.allow?("runtime-limited", :tesla_api)
    assert 0 = TrafficLimiter.remaining("runtime-limited", :tesla_api)
    assert :unlimited = TrafficLimiter.remaining("runtime-limited", :mqtt_publish)
  end

  defp tenant(id, vehicle_ids) do
    {:ok, tenant} =
      Tenant.new(%{
        id: id,
        database: %{
          host: "localhost",
          name: "db_#{id}",
          username: "tm",
          password: "secret"
        },
        mqtt: %{
          namespace: id
        },
        vehicles: Enum.map(vehicle_ids, &%{id: &1, vin: "VIN-#{&1}"})
      })

    tenant
  end
end
