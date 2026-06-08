defmodule TeslaMate.MultiTenant.PolicyTest do
  use ExUnit.Case, async: true

  alias TeslaMate.MultiTenant.Policy
  alias TeslaMate.MultiTenant.Tenant

  test "allows active entitled tenants within vehicle limits" do
    tenant = tenant("policy-allowed", ["car-1", "car-2"], %{max_active_vehicles: 2})

    assert :ok = Policy.allowed?(tenant)
  end

  test "rejects tenants when logging entitlement is disabled" do
    tenant =
      tenant("policy-disabled", ["car-1"])
      |> put_in([Access.key!(:entitlements), "logging"], false)

    assert {:error, :logging_disabled} = Policy.allowed?(tenant)
  end

  test "rejects tenants that exceed active vehicle quota" do
    tenant = tenant("policy-quota", ["car-1", "car-2"], %{max_active_vehicles: 1})

    assert {:error, {:max_active_vehicles_exceeded, 1}} = Policy.allowed?(tenant)
  end

  defp tenant(id, vehicle_ids, limits \\ %{}) do
    {:ok, tenant} =
      Tenant.new(%{
        id: id,
        database: %{host: "localhost", name: "db_#{id}", username: "tm", password: "secret"},
        limits: limits,
        vehicles: Enum.map(vehicle_ids, &%{id: &1})
      })

    tenant
  end
end
