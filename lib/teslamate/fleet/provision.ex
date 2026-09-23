defmodule TeslaMate.Fleet.Provision do
  @moduledoc "Tenant-scoped configuration; the caller cannot choose token, server or fields."
  alias TeslaMate.MultiTenant.{TenantState, TenantSupervisor, Policy, Tenant}

  def run(tenant_id, vin, action) when action in [:configure, :status, :errors] do
    with %Tenant{} = tenant <- TenantState.tenant(tenant_id),
         :ok <- Policy.allowed?(tenant),
         true <- Enum.any?(Policy.active_vehicles(tenant), &(&1.vin == vin)) do
      TeslaMate.Api.fleet_telemetry(TenantSupervisor.api_name(tenant_id), vin, action)
    else
      _ -> {:error, :vehicle_not_assigned}
    end
  catch
    :exit, _ -> {:error, :tenant_unavailable}
  end
end
