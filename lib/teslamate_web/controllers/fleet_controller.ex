defmodule TeslaMateWeb.FleetController do
  use TeslaMateWeb, :controller

  def ingest(conn, %{"tenant_id" => tenant, "record" => record}) do
    case TeslaMate.Fleet.Ingest.ingest(tenant, record) do
      {:ok, result} -> json(conn, %{status: result})
      {:error, :tenant_unavailable} -> conn |> put_status(:service_unavailable) |> json(%{error: "tenant_unavailable"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end
  def ingest(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "invalid_payload"})
end
