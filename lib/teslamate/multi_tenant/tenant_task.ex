defmodule TeslaMate.MultiTenant.TenantTask do
  @moduledoc """
  Task helpers that preserve tenant Repo context.
  """

  alias TeslaMate.MultiTenant.TenantContext

  def async(fun) when is_function(fun, 0) do
    async(TenantContext.tenant_id(), fun)
  end

  def async(nil, fun) when is_function(fun, 0), do: Task.async(fun)

  def async(tenant_id, fun) when is_binary(tenant_id) and is_function(fun, 0) do
    Task.async(fn -> TenantContext.run(tenant_id, fun) end)
  end
end
