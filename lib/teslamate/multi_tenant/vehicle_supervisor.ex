defmodule TeslaMate.MultiTenant.VehicleSupervisor do
  @moduledoc """
  Starts tenant-scoped vehicle workers.

  The worker is intentionally thin for the first POC. It establishes process
  identity and MQTT namespace boundaries before the real TeslaMate logger is
  wired into this supervisor.
  """

  use Supervisor

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    runtime = Keyword.get(opts, :vehicle_runtime, TeslaMate.MultiTenant.vehicle_runtime())

    children =
      tenant
      |> TeslaMate.MultiTenant.Policy.active_vehicles()
      |> Enum.map(fn vehicle ->
        child_spec(runtime, tenant, vehicle, opts)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp child_spec(:placeholder, tenant, vehicle, _opts) do
    {TeslaMate.MultiTenant.VehicleWorker, tenant: tenant, vehicle: vehicle}
  end

  defp child_spec(:logger, tenant, vehicle, opts) do
    materializer = Keyword.get(opts, :materializer, TeslaMate.MultiTenant.VehicleMaterializer)
    car = materializer.create_or_update!(tenant, vehicle)
    api_name = Keyword.fetch!(opts, :api_name)

    {TeslaMate.Vehicles.Vehicle,
     car: car,
     name: TeslaMate.MultiTenant.VehicleWorker.via(tenant.id, vehicle.id),
     tenant_id: tenant.id,
     deps_api: {TeslaMate.Api, api_name},
     deps_vehicles: {TeslaMate.MultiTenant.TenantVehicles, tenant.id}}
  end
end
