defmodule TeslaMate.MultiTenant.Directory do
  @moduledoc """
  Behaviour for tenant directory backends.

  Production deployments should use a control-plane backed implementation such
  as `TeslaMate.MultiTenant.HTTPDirectory`. `FileDirectory` is kept for local
  development and repeatable smoke tests.
  """

  alias TeslaMate.MultiTenant.Tenant

  @callback list_tenants(keyword()) :: {:ok, [Tenant.t()]} | {:error, term()}

  def load(module, opts) do
    with {:ok, tenants} <- module.list_tenants(opts) do
      {:ok, Enum.filter(tenants, &Tenant.active?/1)}
    end
  end

  def parse_tenants(items) when is_list(items) do
    result =
      items
      |> Enum.map(&Tenant.new/1)
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, tenant}, {:ok, acc} -> {:cont, {:ok, [tenant | acc]}}
        {:error, reason}, _acc -> {:halt, {:error, reason}}
      end)

    case result do
      {:ok, tenants} -> {:ok, Enum.reverse(tenants)}
      error -> error
    end
  end

  def parse_tenants(_items), do: {:error, :invalid_tenants}
end
