defmodule TeslaMate.MultiTenant.VehicleWorker do
  @moduledoc """
  Tenant-scoped vehicle process placeholder.

  This process gives every vehicle a stable `{tenant_id, vehicle_id}` identity.
  The next implementation step is to move the existing `TeslaMate.Vehicles.Vehicle`
  logger state machine behind this boundary.
  """

  use GenServer

  alias TeslaMate.MultiTenant.Tenant
  alias TeslaMate.MultiTenant.Tenant.Vehicle

  def start_link(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    vehicle = Keyword.fetch!(opts, :vehicle)

    GenServer.start_link(__MODULE__, {tenant, vehicle}, name: via(tenant.id, vehicle.id))
  end

  def via(tenant_id, vehicle_id) do
    {:via, Registry, {TeslaMate.MultiTenant.Registry, {:vehicle, tenant_id, vehicle_id}}}
  end

  def summary(pid), do: GenServer.call(pid, :summary)

  @impl true
  def init({%Tenant{} = tenant, %Vehicle{} = vehicle}) do
    {:ok,
     %{
       tenant_id: tenant.id,
       vehicle_id: vehicle.id,
       vin: vehicle.vin,
       display_name: vehicle.display_name,
       mqtt_namespace: mqtt_namespace(tenant)
     }}
  end

  @impl true
  def handle_call(:summary, _from, state), do: {:reply, state, state}

  defp mqtt_namespace(%Tenant{mqtt: %TeslaMate.MultiTenant.Tenant.Mqtt{namespace: namespace}}),
    do: namespace

  defp mqtt_namespace(_tenant), do: nil

  def child_spec(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    vehicle = Keyword.fetch!(opts, :vehicle)

    %{
      id: {:vehicle, tenant.id, vehicle.id},
      start: {__MODULE__, :start_link, [opts]}
    }
  end
end
