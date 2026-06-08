defmodule TeslaMate.MultiTenant.TenantState do
  @moduledoc false

  use GenServer

  alias TeslaMate.MultiTenant.Tenant

  def start_link(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    GenServer.start_link(__MODULE__, tenant, name: via(tenant.id))
  end

  def tenant(tenant_id), do: GenServer.call(via(tenant_id), :tenant)
  def fingerprint(tenant_id), do: GenServer.call(via(tenant_id), :fingerprint)

  def via(tenant_id),
    do: {:via, Registry, {TeslaMate.MultiTenant.Registry, {:tenant_state, tenant_id}}}

  @impl true
  def init(%Tenant{} = tenant), do: {:ok, tenant}

  @impl true
  def handle_call(:tenant, _from, tenant), do: {:reply, tenant, tenant}

  @impl true
  def handle_call(:fingerprint, _from, tenant) do
    {:reply, Tenant.fingerprint(tenant), tenant}
  end

  def child_spec(opts) do
    tenant = Keyword.fetch!(opts, :tenant)

    %{
      id: {:tenant_state, tenant.id},
      start: {__MODULE__, :start_link, [opts]}
    }
  end
end
