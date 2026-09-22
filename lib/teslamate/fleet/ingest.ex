defmodule TeslaMate.Fleet.Ingest do
  @moduledoc "Durable inbox. A success response means committed data, not an in-memory notification."
  alias TeslaMate.{Repo, Log}
  alias TeslaMate.Fleet.Event
  alias TeslaMate.MultiTenant.{TenantContext, TenantState, Policy}

  def ingest(tenant_id, %{"vin" => vin} = payload) when is_binary(vin) do
    tenant = TenantState.tenant(tenant_id)
    assigned? = Enum.any?(Policy.active_vehicles(tenant), &(&1.vin == vin))

    if assigned? do
      TenantContext.run(tenant_id, fn ->
        case Log.get_car_by(vin: vin) do
          nil -> {:error, :vehicle_not_materialized}
          car -> store(car, "telemetry", payload)
        end
      end)
    else
      {:error, :vehicle_not_assigned}
    end
  catch
    :exit, _ -> {:error, :tenant_unavailable}
  end
  def ingest(_, _), do: {:error, :invalid_payload}

  def store(car, "telemetry", %{"data" => data} = payload) when is_list(data) and length(data) <= 512 do
    with {:ok, at, _} <- timestamp(payload["createdAt"] || payload["created_at"]),
         true <- DateTime.diff(at, DateTime.utc_now(), :second) <= 300,
         true <- Enum.all?(data, &valid_datum?/1) do
      # is_resend is a transport flag, not part of sample identity. Key order is canonicalized.
      identity = payload |> Map.drop(["isResend", "is_resend"])
      persist(car, "telemetry", at, payload, identity)
    else
      _ -> {:error, :invalid_payload}
    end
  end

  def store(car, "snapshot", %{"drive_state" => %{"timestamp" => ts}} = payload)
      when is_integer(ts) do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, at} -> persist(car, "snapshot", at, payload, payload)
      _ -> {:error, :invalid_payload}
    end
  end
  def store(_, _, _), do: {:error, :invalid_payload}

  defp persist(car, source, at, payload, identity) do
    key = :crypto.hash(:sha256, :erlang.term_to_binary({source, canonical(identity)})) |> Base.encode16(case: :lower)
    {count, _} = Repo.insert_all(Event, [%{car_id: car.id, source: source, event_key: key,
      recorded_at: at, received_at: DateTime.utc_now(), payload: payload, status: "pending"}],
      on_conflict: :nothing, conflict_target: [:car_id, :event_key])
    {:ok, if(count == 1, do: :stored, else: :duplicate)}
  end

  defp timestamp(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp timestamp(_), do: {:error, :invalid_timestamp}
  defp valid_datum?(%{"key" => key, "value" => value}), do: is_binary(key) and is_map(value) and map_size(value) == 1
  defp valid_datum?(_), do: false
  defp canonical(map) when is_map(map), do: map |> Enum.sort() |> Enum.map(fn {k, v} -> {k, canonical(v)} end)
  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
