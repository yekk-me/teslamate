defmodule TeslaMate.MultiTenant.TenantVehicles do
  @moduledoc """
  Adapter used by tenant-scoped logger processes.
  """

  require Logger

  alias TeslaMate.Log
  alias TeslaMate.MultiTenant.RuntimeSupervisor
  alias TeslaMate.MultiTenant.TenantContext
  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Vehicles.Vehicle.Summary

  def list(tenant_id) when is_binary(tenant_id) do
    TenantContext.run(tenant_id, fn ->
      Log.list_cars()
      |> Enum.map(&%Summary{car: &1})
    end)
  end

  def subscribe_to_summary(tenant_id, car_id) do
    Vehicle.subscribe_to_summary(tenant_id, car_id)
  end

  def restart(tenant_id) when is_binary(tenant_id) do
    async_stop(tenant_id)
    :ok
  end

  def kill(tenant_id, car_id) when is_binary(tenant_id) do
    Logger.warning(
      "Vehicle #{car_id} is unhealthy in tenant #{tenant_id}; keeping tenant runtime alive"
    )

    true
  end

  def kill(tenant_id) when is_binary(tenant_id) do
    async_stop(tenant_id)
    true
  end

  defp async_stop(tenant_id) do
    Task.start(fn -> RuntimeSupervisor.stop_tenant(tenant_id) end)
  end
end
