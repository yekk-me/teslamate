defmodule TeslaMateWeb.MultiTenantAuthController do
  use TeslaMateWeb, :controller

  alias TeslaMate.MultiTenant.TenantAuth

  def authorize(conn, %{"tenant_id" => tenant_id} = params) do
    case tenant_auth().authorize(tenant_id, params) do
      {:ok, result} ->
        json(conn, %{data: result})

      {:error, reason} ->
        conn
        |> put_status(status(reason))
        |> json(%{error: format_reason(reason)})
    end
  end

  defp tenant_auth do
    :teslamate
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:tenant_auth, TenantAuth)
  end

  defp status(:missing_tesla_credentials), do: :bad_request
  defp status(:tenant_repo_not_running), do: :conflict
  defp status(%TeslaApi.Error{}), do: :bad_gateway
  defp status(_reason), do: :unprocessable_entity

  defp format_reason(%TeslaApi.Error{} = error), do: Exception.message(error)
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
