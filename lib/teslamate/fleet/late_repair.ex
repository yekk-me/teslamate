defmodule TeslaMate.Fleet.LateRepair do
  @moduledoc "Audited interior-sample repair; never guesses missing session boundaries."
  import Ecto.Query
  alias TeslaMate.{Repo, Log}
  alias TeslaMate.Fleet.{Checkpoint, Decoder, Event, Repair}
  alias TeslaMate.Vehicles.Vehicle

  @processed ~w(projected cached incomplete repaired)
  @fields ~w(Location Odometer VehicleSpeed GpsHeading BatteryLevel Soc IdealBatteryRange EstBatteryRange RatedRange InsideTemp OutsideTemp TpmsPressureFl TpmsPressureFr TpmsPressureRl TpmsPressureRr Gear)
  @metrics ~w(start_date end_date start_position_id end_position_id start_km end_km distance duration_min speed_max start_ideal_range_km end_ideal_range_km start_rated_range_km end_rated_range_km power_max power_min outside_temp_avg inside_temp_avg ascent descent start_address_id end_address_id start_geofence_id end_geofence_id)a

  # Caller holds the per-car checkpoint lock and a transaction. The live
  # checkpoint is never rewound, and repairs cannot close an active session.
  def attempt(event, checkpoint, base) do
    with :ok <- eligible(event),
         {:ok, prior, next} <- context(event, checkpoint),
         :ok <- safe_delta(event, prior, next),
         {:ok, drive} <- closed_drive(event),
         :ok <- unused_timestamp(event),
         snapshot <- Decoder.merge(prior, event.payload, event.recorded_at),
         true <- Decoder.ready?(snapshot),
         vehicle <- TeslaApi.Vehicle.result(snapshot),
         vehicle <- %{vehicle | drive_state: %{vehicle.drive_state | timestamp: event.recorded_at}},
         attrs <- Vehicle.fleet_position_attrs(vehicle, base),
         :ok <- odometer_between_neighbors(drive, attrs) do
      {:ok, position} = Log.insert_position(drive, attrs)
      {:ok, updated} = Log.close_drive(drive, lookup_address: false, preserve_geofences: true)
      # App references and historical session boundaries must stay stable.
      if updated.__meta__.state == :deleted, do: Repo.rollback(:repair_deleted_drive)
      for key <- ~w(id start_date end_date start_position_id end_position_id)a do
        if Map.fetch!(drive, key) != Map.fetch!(updated, key), do: Repo.rollback(:repair_changed_boundary)
      end
      Repo.insert!(%Repair{event_id: event.id, drive_id: drive.id, position_id: position.id,
        before_metrics: metrics(drive), after_metrics: metrics(updated), inserted_at: DateTime.utc_now()})
      Repo.update!(Ecto.Changeset.change(event, status: "repaired", error: nil))
      :repaired
    else
      false -> retain(event, :incomplete_historical_state)
      {:error, reason} -> retain(event, reason)
    end
  end

  # Revisit samples that arrived while their known drive was still open.
  # Older pre-upgrade late events receive the same checks once, with a reason.
  def retry(base, limit \\ 10) do
    ids = Repo.all(from e in Event,
      where: e.car_id == ^base.car.id and e.status == "late" and
        e.error in ["older_than_checkpoint", "repair_waiting_for_closed_drive"],
      order_by: [asc: e.recorded_at, asc: e.id], limit: ^limit, select: e.id)
    Enum.map(ids, fn id ->
      Repo.transaction(fn ->
        checkpoint = Repo.one!(from c in Checkpoint, where: c.car_id == ^base.car.id, lock: "FOR UPDATE")
        event = Repo.one!(from e in Event, where: e.id == ^id and e.car_id == ^base.car.id, lock: "FOR UPDATE")
        if event.status == "late", do: attempt(event, checkpoint, base), else: :already_handled
      end)
    end)
  end

  defp eligible(%Event{source: "telemetry", payload: %{"data" => data}}) do
    keys = Enum.map(data, & &1["key"])
    cond do
      not Enum.all?(keys, &(&1 in @fields)) -> {:error, :unsupported_fields_or_transition}
      not Enum.any?(keys, &(&1 in ~w(Location Odometer VehicleSpeed))) -> {:error, :not_a_driving_sample}
      true -> :ok
    end
  end
  defp eligible(_), do: {:error, :unsupported_source}

  defp context(event, checkpoint) do
    anchor = Repo.one(from e in Event,
      where: e.car_id == ^event.car_id and e.source == "snapshot" and e.status in ^@processed and e.recorded_at < ^event.recorded_at,
      order_by: [desc: e.recorded_at, desc: e.id], limit: 1)
    if anchor && DateTime.diff(event.recorded_at, anchor.recorded_at, :second) <= 86_400 do
      events = Repo.all(from e in Event,
        where: e.car_id == ^event.car_id and e.recorded_at >= ^anchor.recorded_at and e.recorded_at <= ^checkpoint.recorded_at,
        order_by: [asc: e.recorded_at, asc: e.id], limit: 5001)
      {past, future} = Enum.split_while(events, &(DateTime.compare(&1.recorded_at, event.recorded_at) == :lt))
      same_time = Enum.filter(future, &(&1.recorded_at == event.recorded_at))
      past = Enum.drop_while(past, &(&1.id != anchor.id))
      next = Enum.find(future, &(DateTime.compare(&1.recorded_at, event.recorded_at) == :gt))
      cond do
        length(events) > 5000 -> {:error, :replay_limit}
        length(same_time) != 1 -> {:error, :ambiguous_timestamp}
        not Enum.all?(past, &(&1.status in @processed)) -> {:error, :unresolved_earlier_event}
        is_nil(next) || next.status not in @processed -> {:error, :no_processed_successor}
        true -> {:ok, Enum.reduce(past, %{}, &merge/2), next}
      end
    else
      {:error, :missing_recent_snapshot}
    end
  end

  defp merge(%Event{source: "snapshot", payload: payload}, previous),
    do: Map.merge(Map.drop(previous, ["_signals", "_signal_times"]), payload)
  defp merge(%Event{source: "telemetry"} = e, snapshot), do: Decoder.merge(snapshot, e.payload, e.recorded_at)
  defp merge(%Event{source: "status", payload: payload}, snapshot), do: Map.put(snapshot, "state", payload["state"])

  defp safe_delta(event, prior, next) do
    updated = Decoder.merge(prior, event.payload, event.recorded_at)
    gear = get_in(prior, ["drive_state", "shift_state"])
    keys = event.payload["data"] |> Enum.map(& &1["key"]) |> Enum.reject(&(&1 == "Gear")) |> MapSet.new()
    overwritten? = case next.source do
      "snapshot" -> Decoder.ready?(next.payload) && Enum.all?(~w(drive_state charge_state climate_state vehicle_state vehicle_config), &is_map(next.payload[&1]))
      "telemetry" -> MapSet.subset?(keys, MapSet.new(Enum.map(next.payload["data"], & &1["key"])))
      _ -> false
    end
    cond do
      prior["state"] != "online" || gear not in ~w(D N R) -> {:error, :unknown_driving_state}
      get_in(updated, ["drive_state", "shift_state"]) != gear -> {:error, :state_transition_requires_replay}
      not overwritten? -> {:error, :would_change_following_samples}
      true -> :ok
    end
  end

  defp closed_drive(event) do
    drives = Repo.all(from d in Log.Drive,
      where: d.car_id == ^event.car_id and d.start_date < ^event.recorded_at and d.end_date > ^event.recorded_at,
      lock: "FOR UPDATE", limit: 2)
    case drives do
      [drive] -> {:ok, drive}
      [] ->
        if Repo.exists?(from d in Log.Drive, where: d.car_id == ^event.car_id and d.start_date < ^event.recorded_at and is_nil(d.end_date)),
          do: {:error, :waiting_for_closed_drive}, else: {:error, :no_closed_drive}
      _ -> {:error, :overlapping_drives}
    end
  end

  defp unused_timestamp(event) do
    if Repo.exists?(from p in Log.Position, where: p.car_id == ^event.car_id and p.date == ^event.recorded_at),
      do: {:error, :position_already_exists}, else: :ok
  end

  defp odometer_between_neighbors(drive, attrs) do
    before = Repo.one(from p in Log.Position, where: p.drive_id == ^drive.id and p.date < ^attrs.date, order_by: [desc: p.date], limit: 1)
    after_position = Repo.one(from p in Log.Position, where: p.drive_id == ^drive.id and p.date > ^attrs.date, order_by: [asc: p.date], limit: 1)
    if before && after_position && is_number(before.odometer) && is_number(after_position.odometer) && is_number(attrs.odometer) &&
        before.odometer <= attrs.odometer && attrs.odometer <= after_position.odometer,
      do: :ok, else: {:error, :inconsistent_odometer}
  end

  defp retain(event, reason) do
    Repo.update!(Ecto.Changeset.change(event, status: "late", error: "repair_" <> Atom.to_string(reason)))
    :late
  end
  defp metrics(drive), do: drive |> Map.take(@metrics) |> Jason.encode!() |> Jason.decode!()
end
