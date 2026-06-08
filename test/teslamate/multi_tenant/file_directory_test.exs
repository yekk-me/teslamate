defmodule TeslaMate.MultiTenant.FileDirectoryTest do
  use ExUnit.Case, async: false

  alias TeslaMate.MultiTenant.FileDirectory
  alias TeslaMate.MultiTenant.Tenant

  test "loads tenants with database, mqtt and vehicle assignments" do
    path = fixture_path("tenant-directory.json")

    File.write!(path, """
    {
      "tenants": [
        {
          "id": "tenant-a",
          "user_id": "user-a",
          "database": {
            "host": "db.internal",
            "port": 5433,
            "username": "tm_a",
            "password": "secret",
            "name": "teslamate_tenant_a",
            "pooler": "pgbouncer",
            "ssl": true
          },
          "mqtt": {
            "host": "mqtt.internal",
            "port": 1884,
            "namespace": "tenant-a"
          },
          "entitlements": {
            "enabled": true,
            "logging": true
          },
          "limits": {
            "max_vehicles": 3,
            "max_active_vehicles": 2,
            "tesla_api_requests_per_minute": 120,
            "mqtt_publishes_per_minute": 600
          },
          "vehicles": [
            {
              "id": "vehicle-a",
              "vin": "VIN-A",
              "eid": "1001",
              "display_name": "Model Y"
            }
          ]
        }
      ]
    }
    """)

    assert {:ok, [%Tenant{} = tenant]} = FileDirectory.list_tenants(path: path)
    assert tenant.id == "tenant-a"
    assert tenant.user_id == "user-a"
    assert tenant.database.name == "teslamate_tenant_a"
    assert tenant.database.host == "db.internal"
    assert tenant.database.port == 5433
    assert tenant.database.ssl == true
    assert tenant.database.pooler == "pgbouncer"
    assert tenant.database.prepare == :unnamed
    assert Tenant.Database.repo_opts(tenant.database, :repo)[:prepare] == :unnamed
    assert tenant.mqtt.namespace == "tenant-a"
    assert tenant.entitlements["logging"] == true
    assert tenant.limits.max_vehicles == 3
    assert tenant.limits.max_active_vehicles == 2
    assert tenant.limits.tesla_api_requests_per_minute == 120
    assert tenant.limits.mqtt_publishes_per_minute == 600
    assert [%Tenant.Vehicle{id: "vehicle-a", vin: "VIN-A"}] = tenant.vehicles
  end

  test "returns a clear error when path is missing" do
    assert {:error, :tenant_directory_path_missing} = FileDirectory.list_tenants(path: nil)
  end

  test "rejects tenants without explicit database credentials" do
    path = fixture_path("tenant-directory-invalid-db.json")

    File.write!(path, """
    {
      "tenants": [
        {
          "id": "tenant-a",
          "database": {
            "name": "teslamate_tenant_a"
          }
        }
      ]
    }
    """)

    assert {:error, {:missing, "database.host"}} = FileDirectory.list_tenants(path: path)
  end

  test "rejects invalid database prepare mode" do
    path = fixture_path("tenant-directory-invalid-prepare.json")

    File.write!(path, """
    {
      "tenants": [
        {
          "id": "tenant-a",
          "database": {
            "host": "db.internal",
            "username": "tm_a",
            "password": "secret",
            "name": "teslamate_tenant_a",
            "prepare": "invalid"
          }
        }
      ]
    }
    """)

    assert {:error, {:invalid, "database.prepare", "invalid"}} =
             FileDirectory.list_tenants(path: path)
  end

  defp fixture_path(name) do
    path = Path.join(System.tmp_dir!(), "teslamate-#{System.unique_integer([:positive])}-#{name}")
    on_exit(fn -> File.rm(path) end)
    path
  end
end
