defmodule TeslaMate.MultiTenant.RuntimeSupervisor do
  @moduledoc """
  Dynamic supervisor for tenant runtimes.

  The supervisor keeps one child per active tenant. Syncing is idempotent: new
  tenants are started, removed tenants are stopped, and existing tenants are
  left running until a later config-change restart path is added.
  """

  use DynamicSupervisor

  require Logger

  alias TeslaMate.MultiTenant.Tenant
  alias TeslaMate.MultiTenant.TenantState
  alias TeslaMate.MultiTenant.TenantSupervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  def sync(supervisor \\ __MODULE__, tenants) when is_list(tenants) do
    tenants = TeslaMate.MultiTenant.Policy.allowed_tenants(tenants)
    desired_ids = tenants |> Enum.map(& &1.id) |> MapSet.new()
    running = running_tenants(supervisor)

    running
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(desired_ids, &1))
    |> Enum.each(&stop_tenant(supervisor, &1))

    errors =
      tenants
      |> Enum.reduce([], fn tenant, acc ->
        case Map.fetch(running, tenant.id) do
          :error ->
            collect_start_error(supervisor, tenant, acc)

          {:ok, _pid} ->
            if tenant_changed?(tenant) do
              :ok = stop_tenant(supervisor, tenant.id)
              collect_start_error(supervisor, tenant, acc)
            else
              acc
            end
        end
      end)

    case errors do
      [] -> :ok
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  def running_tenants(supervisor \\ __MODULE__) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.reduce(%{}, fn {_id, pid, _type, _modules}, acc ->
      case TenantSupervisor.tenant_id(pid) do
        {:ok, tenant_id} -> Map.put(acc, tenant_id, pid)
        _ -> acc
      end
    end)
  end

  def start_tenant(supervisor \\ __MODULE__, %Tenant{} = tenant) do
    Logger.info("Starting tenant runtime #{tenant.id}")

    spec =
      {TenantSupervisor,
       tenant: tenant,
       start_repo?: TeslaMate.MultiTenant.start_repo?(),
       start_vehicle_workers?: TeslaMate.MultiTenant.start_vehicle_workers?()}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_tenant(supervisor \\ __MODULE__, tenant_id) when is_binary(tenant_id) do
    case Map.fetch(running_tenants(supervisor), tenant_id) do
      {:ok, pid} ->
        Logger.info("Stopping tenant runtime #{tenant_id}")
        DynamicSupervisor.terminate_child(supervisor, pid)

      :error ->
        :ok
    end
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  defp tenant_changed?(%Tenant{id: tenant_id} = tenant) do
    TenantState.fingerprint(tenant_id) != Tenant.fingerprint(tenant)
  rescue
    _ -> true
  end

  defp collect_start_error(supervisor, tenant, acc) do
    case start_tenant(supervisor, tenant) do
      :ok -> acc
      {:error, reason} -> [{tenant.id, reason} | acc]
    end
  end
end
