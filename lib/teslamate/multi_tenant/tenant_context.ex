defmodule TeslaMate.MultiTenant.TenantContext do
  @moduledoc """
  Process-local tenant context for routing `TeslaMate.Repo` calls.

  Ecto dynamic repos are stored in the current process dictionary, so every
  long-lived process and every task that touches TeslaMate data must enter this
  context before calling existing contexts such as `TeslaMate.Log`.
  """

  alias TeslaMate.MultiTenant.TenantSupervisor

  @tenant_key {__MODULE__, :tenant_id}

  def tenant_id, do: Process.get(@tenant_key)

  def run(nil, fun) when is_function(fun, 0), do: fun.()

  def run(tenant_id, fun) when is_binary(tenant_id) and is_function(fun, 0) do
    previous = put(tenant_id)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  def put(tenant_id) when is_binary(tenant_id) do
    repo = repo_pid!(tenant_id)
    previous_tenant = Process.put(@tenant_key, tenant_id)
    previous_repo = TeslaMate.Repo.put_dynamic_repo(repo)
    {previous_tenant, previous_repo}
  end

  def repo_pid!(tenant_id) when is_binary(tenant_id) do
    case Registry.lookup(TeslaMate.MultiTenant.Registry, {:repo, tenant_id}) do
      [{pid, _value}] ->
        pid

      [] ->
        raise "tenant repo is not running for #{inspect(tenant_id)}"
    end
  end

  def repo_name(tenant_id), do: TenantSupervisor.repo_name(tenant_id)

  defp restore({nil, previous_repo}) do
    Process.delete(@tenant_key)
    TeslaMate.Repo.put_dynamic_repo(previous_repo)
  end

  defp restore({previous_tenant, previous_repo}) do
    Process.put(@tenant_key, previous_tenant)
    TeslaMate.Repo.put_dynamic_repo(previous_repo)
  end
end
