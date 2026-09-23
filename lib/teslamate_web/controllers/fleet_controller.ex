defmodule TeslaMateWeb.FleetController do
  use TeslaMateWeb, :controller

  def callback(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_content_type("text/html")
    |> send_resp(200, "<!doctype html><meta charset=utf-8><title>Fleet 授权回调</title><p>请将地址栏完整链接粘贴回服务器上的账号授权工具。不要将此链接分享给他人。</p>")
  end

  def configure(conn, %{"tenant_id" => tenant, "vin" => vin}),
    do: provision(conn, tenant, vin, :configure)

  def configuration(conn, %{"tenant_id" => tenant, "vin" => vin}),
    do: provision(conn, tenant, vin, :status)

  def errors(conn, %{"tenant_id" => tenant, "vin" => vin}),
    do: provision(conn, tenant, vin, :errors)

  defp provision(conn, tenant, vin, action) do
    case TeslaMate.Fleet.Provision.run(tenant, vin, action) do
      {:ok, result} -> json(conn, %{data: result})
      {:error, reason} when is_atom(reason) ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
      _ -> conn |> put_status(:bad_gateway) |> json(%{error: "telemetry_request_failed"})
    end
  end

  def status(conn, %{"tenant_id" => tenant}) do
    result =
      TeslaMate.MultiTenant.TenantContext.run(tenant, fn ->
        import Ecto.Query

        TeslaMate.Repo.all(
          from e in TeslaMate.Fleet.Event,
            group_by: [e.car_id, e.source, e.status],
            select: %{
              car_id: e.car_id,
              source: e.source,
              status: e.status,
              count: count(e.id),
              oldest: min(e.recorded_at),
              newest: max(e.recorded_at)
            }
        )
      end)

    json(conn, %{data: result})
  rescue
    _ in [RuntimeError, DBConnection.ConnectionError] ->
      conn |> put_status(:service_unavailable) |> json(%{error: "tenant_unavailable"})
  end

  def ingest(conn, %{"tenant_id" => tenant, "record" => record}) do
    case TeslaMate.Fleet.Ingest.ingest(tenant, record) do
      {:ok, result} ->
        json(conn, %{status: result})

      {:error, :tenant_unavailable} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "tenant_unavailable"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  def ingest(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "invalid_payload"})
end
