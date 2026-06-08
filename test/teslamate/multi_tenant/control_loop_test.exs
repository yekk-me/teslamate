defmodule TeslaMate.MultiTenant.ControlLoopTest do
  use ExUnit.Case, async: false

  alias TeslaMate.MultiTenant.ControlLoop
  alias TeslaMate.MultiTenant.RuntimeSupervisor

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

  test "syncs tenant directory into runtime supervisor", %{supervisor: supervisor} do
    path = fixture_path("tenant-directory.json")

    File.write!(path, """
    {
      "tenants": [
        {
          "id": "control-loop-a",
          "database": {
            "host": "localhost",
            "name": "db_tenant_a",
            "username": "tm",
            "password": "secret"
          },
          "mqtt": {"namespace": "control-loop-a"},
          "vehicles": [{"id": "control-car-1"}]
        }
      ]
    }
    """)

    loop =
      start_supervised!(
        {ControlLoop,
         directory_opts: [path: path], runtime_supervisor: supervisor, interval: :timer.hours(1)}
      )

    assert :ok = ControlLoop.sync(loop)
    assert %{"control-loop-a" => _} = RuntimeSupervisor.running_tenants(supervisor)
  end

  test "stops tenants after repeated directory sync failures", %{supervisor: supervisor} do
    path = fixture_path("tenant-directory-fail-closed.json")

    File.write!(path, """
    {
      "tenants": [
        {
          "id": "control-loop-fail-closed",
          "database": {
            "host": "localhost",
            "name": "db_tenant_a",
            "username": "tm",
            "password": "secret"
          },
          "mqtt": {"namespace": "control-loop-fail-closed"},
          "vehicles": [{"id": "control-car-1"}]
        }
      ]
    }
    """)

    loop =
      start_supervised!(
        {ControlLoop,
         directory_opts: [path: path],
         runtime_supervisor: supervisor,
         interval: :timer.hours(1),
         max_failures: 1}
      )

    assert :ok = ControlLoop.sync(loop)
    assert %{"control-loop-fail-closed" => _} = RuntimeSupervisor.running_tenants(supervisor)

    File.rm!(path)

    assert {:error, {:tenant_directory_not_found, ^path}} = ControlLoop.sync(loop)
    assert %{} = RuntimeSupervisor.running_tenants(supervisor)
  end

  defp fixture_path(name) do
    path = Path.join(System.tmp_dir!(), "teslamate-#{System.unique_integer([:positive])}-#{name}")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
