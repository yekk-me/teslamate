defmodule TeslaMateWeb.FleetController do
  use TeslaMateWeb, :controller

  def status(conn, %{"tenant_id" => tenant}) do
    result = TeslaMate.MultiTenant.TenantContext.run(tenant, fn ->
      import Ecto.Query
      TeslaMate.Repo.all(from e in TeslaMate.Fleet.Event,
        group_by: [e.car_id, e.source, e.status],
        select: %{car_id: e.car_id, source: e.source, status: e.status,
          count: count(e.id), oldest: min(e.recorded_at), newest: max(e.recorded_at)})
    end)
    json(conn, %{data: result})
  rescue
    _ in [RuntimeError, DBConnection.ConnectionError] -> conn |> put_status(:service_unavailable) |> json(%{error: "tenant_unavailable"})
  end

  def ingest(conn, %{"tenant_id" => tenant, "record" => record}) do
    case TeslaMate.Fleet.Ingest.ingest(tenant, record) do
      {:ok, result} -> json(conn, %{status: result})
      {:error, :tenant_unavailable} -> conn |> put_status(:service_unavailable) |> json(%{error: "tenant_unavailable"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end
  def ingest(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "invalid_payload"})
end
