defmodule TeslaMate.Fleet.Projector do
  @moduledoc "Reuses the existing logger transitions; inbox progress and all record writes commit together."
  import Ecto.Query
  alias TeslaMate.Repo
  alias TeslaMate.Fleet.{Checkpoint, Decoder, Event}
  alias TeslaMate.Vehicles.Vehicle

  @saved_fields [:last_used, :last_response, :last_state_change, :elevation, :geofence, :fleet_last_position_at]

  def restore(base) do
    case Repo.get(Checkpoint, base.car.id) do
      %Checkpoint{version: 1, logger_state: binary} when is_binary(binary) ->
        {state, saved} = :erlang.binary_to_term(binary, [:safe])
        {state, struct(base, saved)}
      nil -> {:start, base}
      %Checkpoint{version: 1, logger_state: nil} -> {:start, base}
      _ -> raise "Unsupported Fleet checkpoint version"
    end
  end

  def step(base, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = DateTime.add(now, -Keyword.get(opts, :reorder_seconds, reorder_seconds()), :second)
    Repo.transaction(fn ->
      Repo.insert_all(Checkpoint, [%{car_id: base.car.id, updated_at: now, snapshot: %{}, version: 1}],
        on_conflict: :nothing, conflict_target: [:car_id])
      checkpoint = Repo.one!(from(c in Checkpoint, where: c.car_id == ^base.car.id, lock: "FOR UPDATE"))
      event = Repo.one(from(e in Event, where: e.car_id == ^base.car.id and e.status == "pending",
        order_by: [asc: e.recorded_at, asc: e.id], limit: 1, lock: "FOR UPDATE"))
      if event && DateTime.compare(event.received_at, cutoff) != :gt, do: project(event, checkpoint, base), else: :empty
    end)
  end

  defp project(event, checkpoint, base) do
    if checkpoint.recorded_at && DateTime.compare(event.recorded_at, checkpoint.recorded_at) == :lt do
      # Never overwrite newer values or attach an old sample to the current drive.
      # Retain the complete original event for explicit offline replay/reconciliation.
      Repo.update!(Ecto.Changeset.change(event, status: "late", error: "older_than_checkpoint"))
      :late
    else
      snapshot = case event.source do
        "telemetry" -> Decoder.merge(checkpoint.snapshot, event.payload, event.recorded_at)
        "snapshot" -> merge_snapshot(checkpoint.snapshot, event.payload)
        "status" -> checkpoint.snapshot |> Map.put("state", event.payload["state"])
      end
      {state, data} = restore(base)
      {state, data, status} =
        if event.source == "status" or Decoder.ready?(snapshot) do
          vehicle = TeslaApi.Vehicle.result(snapshot)
          vehicle = if event.source == "status", do: %{vehicle | drive_state: %TeslaApi.Vehicle.State.Drive{timestamp: DateTime.to_unix(event.recorded_at, :millisecond)}}, else: vehicle
          data = %{data | last_response: vehicle, last_used: event.recorded_at}
          kind = case snapshot["state"] do
            "asleep" -> :asleep
            "offline" -> :offline
            _ -> :online
          end
          previous = state
          {state, data} = advance(state, data, {:update, {kind, vehicle}}, 0)
          data = store_parked_position(previous, state, data, event.recorded_at)
          {state, data, "projected"}
        else
          {state, data, "incomplete"}
        end
      binary = :erlang.term_to_binary({state, Map.take(data, @saved_fields)}, [:compressed])
      Repo.update!(Ecto.Changeset.change(checkpoint, snapshot: snapshot, logger_state: binary,
        recorded_at: event.recorded_at, updated_at: DateTime.utc_now()))
      Repo.update!(Ecto.Changeset.change(event, status: status))
      {status, state, data}
    end
  end

  defp reorder_seconds do
    System.get_env("TESLA_FLEET_REORDER_SECONDS", "10") |> String.to_integer() |> max(0)
  end

  defp merge_snapshot(previous, current) do
    # A REST snapshot is authoritative at its timestamp. Do not retain telemetry
    # power/energy caches across it; subsequent changed signals rebuild the cache.
    Map.merge(Map.drop(previous, ["_signals", "_signal_times"]), current)
  end

  defp store_parked_position(previous, state, data, at) do
    stationary? = state == :online or match?({:charging, _}, state)
    last = data.fleet_last_position_at
    if stationary? and previous == state and (is_nil(last) or DateTime.diff(at, last) >= 300) do
      Vehicle.handle_event({:timeout, :store_position}, :store_position, state, data)
      %{data | fleet_last_position_at: at}
    else
      if stationary? and previous != state, do: %{data | fleet_last_position_at: at}, else: data
    end
  end

  # Run all immediate state-machine updates inside the same DB transaction.
  # Poll timers and PubSub effects are owned by the Fleet worker, outside this transaction.
  defp advance(_state, _data, _event, depth) when depth > 32, do: Repo.rollback(:transition_loop)
  defp advance(state, data, event, depth) do
    result = Vehicle.handle_event(:internal, event, state, data)
    {next_state, next_data, actions} = normalize(result, state, data)
    next_data = if next_state != state, do: %{next_data | last_state_change: data.last_used}, else: next_data
    actions = if next_state == :start and state != :start and match?({:update, {kind, _}} when kind in [:asleep, :offline], event), do: [{:next_event, :internal, event}], else: actions
    actions = List.wrap(actions)
    Enum.reduce(actions, {next_state, next_data}, fn
      {:next_event, :internal, {:update, _} = update}, {s, d} -> advance(s, d, update, depth + 1)
      _, acc -> acc
    end)
  end

  defp normalize({:next_state, s, d, actions}, _, _), do: {s, d, actions}
  defp normalize({:next_state, s, d}, _, _), do: {s, d, []}
  defp normalize({:keep_state, d, actions}, s, _), do: {s, d, actions}
  defp normalize({:keep_state, d}, s, _), do: {s, d, []}
  defp normalize({:keep_state_and_data, actions}, s, d), do: {s, d, actions}
  defp normalize(:keep_state_and_data, s, d), do: {s, d, []}
end
