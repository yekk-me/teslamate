defmodule TeslaMate.MultiTenant.VehicleMaterializer do
  @moduledoc """
  Creates or updates the tenant-local `cars` row used by the logger state machine.
  """

  alias TeslaMate.MultiTenant.Tenant
  alias TeslaMate.MultiTenant.Tenant.Vehicle
  alias TeslaMate.MultiTenant.TenantContext

  def create_or_update!(%Tenant{id: tenant_id}, %Vehicle{} = vehicle) do
    TenantContext.run(tenant_id, fn ->
      vehicle
      |> to_tesla_vehicle!()
      |> TeslaMate.Vehicles.create_or_update!()
    end)
  end

  def to_tesla_vehicle!(%Vehicle{} = vehicle) do
    %TeslaApi.Vehicle{
      id: integer!(vehicle.eid || vehicle.id, "vehicle.eid"),
      vehicle_id: integer_or_nil(vehicle.vid),
      vin: required_string!(vehicle.vin, "vehicle.vin"),
      display_name: vehicle.display_name
    }
  end

  defp required_string!(value, label) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: raise("#{label} is required"), else: value
  end

  defp required_string!(_value, label), do: raise("#{label} is required")

  defp integer!(value, label) do
    case integer_or_nil(value) do
      nil -> raise("#{label} must be an integer")
      value -> value
    end
  end

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer_or_nil(_value), do: nil
end
