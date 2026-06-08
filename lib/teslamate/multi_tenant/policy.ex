defmodule TeslaMate.MultiTenant.Policy do
  @moduledoc """
  Tenant policy gate for permissions and static quotas.

  This module is independent from the current orchestrator. The tenant directory
  can later be backed by a local database or control service while the runtime
  keeps the same allow/deny contract.
  """

  require Logger

  alias TeslaMate.MultiTenant.Tenant
  alias TeslaMate.MultiTenant.Tenant.Limits
  alias TeslaMate.MultiTenant.Tenant.Vehicle

  def allowed_tenants(tenants) when is_list(tenants) do
    tenants
    |> Enum.reduce([], fn tenant, acc ->
      case allowed?(tenant) do
        :ok ->
          [tenant | acc]

        {:error, reason} ->
          Logger.warning("Tenant #{tenant.id} is not allowed to run: #{inspect(reason)}")
          acc
      end
    end)
    |> Enum.reverse()
  end

  def allowed?(%Tenant{} = tenant) do
    with :ok <- active_tenant?(tenant),
         :ok <- logging_entitled?(tenant),
         :ok <- within_vehicle_limit?(tenant),
         :ok <- within_active_vehicle_limit?(tenant) do
      :ok
    end
  end

  def active_vehicles(%Tenant{vehicles: vehicles}) do
    Enum.filter(vehicles, &Vehicle.active?/1)
  end

  defp active_tenant?(%Tenant{} = tenant) do
    if Tenant.active?(tenant), do: :ok, else: {:error, :tenant_inactive}
  end

  defp logging_entitled?(%Tenant{entitlements: entitlements}) when is_map(entitlements) do
    cond do
      disabled?(Map.get(entitlements, "enabled")) -> {:error, :tenant_disabled}
      disabled?(Map.get(entitlements, "logging")) -> {:error, :logging_disabled}
      true -> :ok
    end
  end

  defp logging_entitled?(_tenant), do: :ok

  defp within_vehicle_limit?(%Tenant{vehicles: vehicles, limits: %Limits{max_vehicles: limit}})
       when is_integer(limit) do
    if length(vehicles) <= limit, do: :ok, else: {:error, {:max_vehicles_exceeded, limit}}
  end

  defp within_vehicle_limit?(_tenant), do: :ok

  defp within_active_vehicle_limit?(%Tenant{limits: %Limits{max_active_vehicles: limit}} = tenant)
       when is_integer(limit) do
    if length(active_vehicles(tenant)) <= limit,
      do: :ok,
      else: {:error, {:max_active_vehicles_exceeded, limit}}
  end

  defp within_active_vehicle_limit?(_tenant), do: :ok

  defp disabled?(value), do: value in [false, "false", "0", 0, "no", "off"]
end
