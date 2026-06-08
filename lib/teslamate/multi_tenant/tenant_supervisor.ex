defmodule TeslaMate.MultiTenant.TenantSupervisor do
  @moduledoc """
  Tenant-scoped supervision tree.

  This is the boundary where database pools, Tesla API state, vehicle workers
  and MQTT namespacing become tenant-local.
  """

  use Supervisor

  alias TeslaMate.MultiTenant.Tenant
  alias TeslaMate.MultiTenant.Tenant.{Database, Mqtt}

  def start_link(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    Supervisor.start_link(__MODULE__, opts, name: via(tenant.id))
  end

  def tenant_id(pid) when is_pid(pid) do
    tenant_id =
      TeslaMate.MultiTenant.Registry
      |> Registry.keys(pid)
      |> Enum.find_value(fn
        {:tenant, tenant_id} -> tenant_id
        _key -> nil
      end)

    case tenant_id do
      nil -> :error
      value -> {:ok, value}
    end
  end

  def via(tenant_id), do: {:via, Registry, {TeslaMate.MultiTenant.Registry, {:tenant, tenant_id}}}

  def repo_name(tenant_id),
    do: {:via, Registry, {TeslaMate.MultiTenant.Registry, {:repo, tenant_id}}}

  def api_name(tenant_id),
    do: {:via, Registry, {TeslaMate.MultiTenant.Registry, {:api, tenant_id}}}

  def vehicle_supervisor_name(tenant_id),
    do: {:via, Registry, {TeslaMate.MultiTenant.Registry, {:vehicle_supervisor, tenant_id}}}

  def mqtt_name(tenant_id),
    do: {:via, Registry, {TeslaMate.MultiTenant.Registry, {:mqtt, tenant_id}}}

  def mqtt_publisher_name(tenant_id),
    do: {:via, Registry, {TeslaMate.MultiTenant.Registry, {:mqtt_publisher, tenant_id}}}

  def mqtt_pubsub_name(tenant_id),
    do: {:via, Registry, {TeslaMate.MultiTenant.Registry, {:mqtt_pubsub, tenant_id}}}

  @impl true
  def init(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    start_repo? = Keyword.get(opts, :start_repo?, true)
    start_vehicle_workers? = Keyword.get(opts, :start_vehicle_workers?, true)

    children =
      [
        {TeslaMate.MultiTenant.TenantState, tenant: tenant},
        {TeslaMate.MultiTenant.TrafficLimiter, tenant: tenant},
        repo_child(tenant, start_repo?),
        api_child(tenant, start_repo?),
        vehicle_supervisor_child(tenant, start_vehicle_workers?),
        mqtt_child(tenant, start_vehicle_workers? and TeslaMate.MultiTenant.start_mqtt?())
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp repo_child(%Tenant{id: tenant_id, database: %Database{} = database}, true) do
    repo_opts = Database.repo_opts(database, repo_name(tenant_id))

    %{
      id: {:repo, tenant_id},
      start: {TeslaMate.Repo, :start_link, [repo_opts]},
      type: :supervisor
    }
  end

  defp repo_child(_tenant, _start_repo?), do: nil

  defp api_child(%Tenant{id: tenant_id}, true) do
    %{
      id: {:api, tenant_id},
      start:
        {TeslaMate.Api, :start_link,
         [
           [
             name: api_name(tenant_id),
             tenant_id: tenant_id,
             vehicles: {TeslaMate.MultiTenant.TenantVehicles, tenant_id}
           ]
         ]}
    }
  end

  defp api_child(_tenant, _start_repo?), do: nil

  defp vehicle_supervisor_child(%Tenant{} = tenant, true) do
    %{
      id: {:vehicles, tenant.id},
      start:
        {TeslaMate.MultiTenant.VehicleSupervisor, :start_link,
         [
           [
             tenant: tenant,
             name: vehicle_supervisor_name(tenant.id),
             vehicle_runtime: TeslaMate.MultiTenant.vehicle_runtime(),
             api_name: api_name(tenant.id)
           ]
         ]},
      type: :supervisor
    }
  end

  defp vehicle_supervisor_child(_tenant, _start_vehicle_workers?), do: nil

  defp mqtt_child(%Tenant{mqtt: %Mqtt{disabled: true}}, _start_mqtt?), do: nil
  defp mqtt_child(_tenant, false), do: nil

  defp mqtt_child(%Tenant{id: tenant_id, mqtt: %Mqtt{} = mqtt}, true) do
    %{
      id: {:mqtt, tenant_id},
      start:
        {TeslaMate.Mqtt, :start_link,
         [
           [
             name: mqtt_name(tenant_id),
             tenant_id: tenant_id,
             publisher_name: mqtt_publisher_name(tenant_id),
             pubsub_name: mqtt_pubsub_name(tenant_id),
             host: mqtt.host,
             port: mqtt.port,
             username: mqtt.username,
             password: mqtt.password,
             tls: mqtt.tls,
             namespace: mqtt.namespace,
             vehicles: {TeslaMate.MultiTenant.TenantVehicles, tenant_id}
           ]
         ]},
      type: :supervisor
    }
  end

  def child_spec(opts) do
    tenant = Keyword.fetch!(opts, :tenant)

    %{
      id: {:tenant, tenant.id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
end
