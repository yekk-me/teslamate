defmodule TeslaMate.MultiTenant.TenantAuth do
  @moduledoc """
  Service entrypoint used by the control plane to authorize a tenant.

  The tenant runtime must already be present with a running tenant Repo. In the
  normal production flow the control plane creates an active tenant with no
  vehicles first, calls this service after Tesla OAuth succeeds, then persists
  the returned vehicle assignments in the control-plane directory.
  """

  alias TeslaApi.Auth
  alias TeslaMate.MultiTenant.TenantContext

  def authorize(tenant_id, attrs, opts \\ []) when is_binary(tenant_id) and is_map(attrs) do
    attrs = stringify_keys(attrs)

    with :ok <- ensure_tenant_repo(tenant_id, opts),
         {:ok, auth} <- auth_from_attrs(attrs, opts),
         {:ok, auth} <- maybe_refresh(auth, attrs, opts),
         {:ok, vehicles} <- vehicle_api(opts).list(auth),
         :ok <- save_auth(tenant_id, auth, opts) do
      {:ok,
       %{
         tenant_id: tenant_id,
         vehicles: Enum.map(vehicles, &vehicle_assignment/1)
       }}
    end
  end

  defp ensure_tenant_repo(tenant_id, opts) do
    run_in_tenant_repo(tenant_id, fn -> :ok end, opts)
  end

  defp auth_from_attrs(attrs, opts) do
    token = string_or_nil(Map.get(attrs, "access_token") || Map.get(attrs, "token"))
    refresh_token = string_or_nil(Map.get(attrs, "refresh_token"))
    code = string_or_nil(Map.get(attrs, "code"))

    cond do
      token && refresh_token ->
        {:ok,
         %Auth{
           token: token,
           refresh_token: refresh_token,
           expires_in: int_or_nil(Map.get(attrs, "expires_in")) || 600,
           created_at: int_or_nil(Map.get(attrs, "created_at"))
         }}

      code ->
        auth_api(opts).exchange_code(code, code_exchange_opts(attrs))

      true ->
        {:error, :missing_tesla_credentials}
    end
  end

  defp maybe_refresh(%Auth{} = auth, attrs, opts) do
    if string_or_nil(Map.get(attrs, "code")) do
      {:ok, auth}
    else
      auth_api(opts).refresh(auth)
    end
  end

  defp save_auth(tenant_id, %Auth{} = auth, opts) do
    auth_context = Keyword.get(opts, :auth_context, TeslaMate.Auth)

    run_in_tenant_repo(tenant_id, fn -> auth_context.save(auth) end, opts)
  end

  defp run_in_tenant_repo(tenant_id, fun, opts) when is_function(fun, 0) do
    repo_runner = Keyword.get(opts, :repo_runner, &TenantContext.run/2)

    repo_runner.(tenant_id, fun)
  rescue
    e in RuntimeError ->
      if String.contains?(Exception.message(e), "tenant repo is not running") do
        {:error, :tenant_repo_not_running}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp vehicle_assignment(%TeslaApi.Vehicle{} = vehicle) do
    %{
      id: to_string(vehicle.id),
      eid: to_string(vehicle.id),
      vid: to_string(vehicle.vehicle_id),
      vin: vehicle.vin,
      display_name: vehicle.display_name,
      state: vehicle.state,
      status: "active"
    }
  end

  defp code_exchange_opts(attrs) do
    [
      redirect_uri: string_or_nil(Map.get(attrs, "redirect_uri")),
      code_verifier: string_or_nil(Map.get(attrs, "code_verifier")),
      issuer_url: string_or_nil(Map.get(attrs, "issuer_url"))
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp auth_api(opts), do: Keyword.get(opts, :auth_api, TeslaApi.Auth)
  defp vehicle_api(opts), do: Keyword.get(opts, :vehicle_api, TeslaApi.Vehicle)

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(_value), do: nil

  defp int_or_nil(value) when is_integer(value), do: value

  defp int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp int_or_nil(_value), do: nil
end
