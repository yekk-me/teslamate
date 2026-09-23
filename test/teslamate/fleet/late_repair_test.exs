defmodule TeslaMate.Fleet.LateRepairTest do
  use TeslaMate.DataCase
  import TeslaMate.FleetFixture
  alias TeslaMate.{Repo, Log}
  alias TeslaMate.Fleet.{Ingest, Projector, Checkpoint, Event, Repair, LateRepair}

  setup do
    {:ok, car} = Log.create_car(%{eid: 9201, vid: 9202, vin: "LRW00000000000003"})

    base = %TeslaMate.Vehicles.Vehicle.Data{
      car: car,
      fleet?: true,
      import?: true,
      deps: %{log: Log, locations: TeslaMate.Locations}
    }

    Ingest.store(car, "snapshot", snapshot(car))
    step(base)
    push(base, 1, %{"Gear" => "ShiftStateD", "VehicleSpeed" => 30.0})
    %{car: car, base: base}
  end

  defp step(base), do: Projector.step(base, reorder_seconds: 0)

  defp push(base, seconds, fields) do
    {:ok, :stored} = Ingest.store(base.car, "telemetry", record(base.car, seconds, fields))
    step(base)
  end

  defp finish(base) do
    push(base, 121, %{"Gear" => "ShiftStateP", "Odometer" => 10002.123456, "VehicleSpeed" => 0.0})
    Repo.one!(from d in Log.Drive, where: d.car_id == ^base.car.id)
  end

  test "late interior samples match ordered projection without moving live state or session IDs",
       %{base: base, car: car} do
    before = finish(base)
    checkpoint = Repo.get!(Checkpoint, car.id)
    late = record(car, 61, %{"Odometer" => 10001.123456, "VehicleSpeed" => 60.0})
    {:ok, :stored} = Ingest.store(car, "telemetry", late)
    assert {:ok, :repaired} = step(base)
    after_drive = Repo.get!(Log.Drive, before.id)

    assert Map.take(before, [:id, :start_date, :end_date, :start_position_id, :end_position_id]) ==
             Map.take(after_drive, [
               :id,
               :start_date,
               :end_date,
               :start_position_id,
               :end_position_id
             ])

    assert after_drive.speed_max == 97
    assert Repo.get!(Checkpoint, car.id) == checkpoint
    [audit] = Repo.all(Repair)
    assert audit.drive_id == before.id
    assert audit.before_metrics["speed_max"] == 48
    assert audit.after_metrics["speed_max"] == 97
    assert Repo.get!(Event, audit.event_id).status == "repaired"
    assert Repo.get!(Log.Position, audit.position_id).date == ~U[2026-01-01 00:01:01.000000Z]
    count = Repo.aggregate(Log.Position, :count)
    assert {:ok, :duplicate} = Ingest.store(car, "telemetry", Map.put(late, "isResend", true))
    assert {:ok, :empty} = step(base)
    assert LateRepair.retry(base) == []
    assert Repo.aggregate(Log.Position, :count) == count

    {:ok, reference} = Log.create_car(%{eid: 9301, vid: 9302, vin: "LRW00000000000004"})
    refbase = %{base | car: reference}
    Ingest.store(reference, "snapshot", snapshot(reference))
    step(refbase)
    push(refbase, 1, %{"Gear" => "ShiftStateD", "VehicleSpeed" => 30.0})
    push(refbase, 61, %{"Odometer" => 10001.123456, "VehicleSpeed" => 60.0})
    expected = finish(refbase)

    keys = [
      :start_date,
      :end_date,
      :distance,
      :duration_min,
      :speed_max,
      :power_max,
      :power_min,
      :outside_temp_avg,
      :inside_temp_avg,
      :ascent,
      :descent,
      :start_ideal_range_km,
      :end_ideal_range_km,
      :start_rated_range_km,
      :end_rated_range_km
    ]

    assert Map.take(after_drive, keys) == Map.take(expected, keys)

    positions = fn id ->
      Repo.all(from p in Log.Position, where: p.drive_id == ^id, order_by: p.date)
      |> Enum.map(
        &Map.take(&1, [:date, :odometer, :latitude, :longitude, :speed, :power, :battery_level])
      )
    end

    assert positions.(before.id) == positions.(expected.id)
  end

  test "open-drive sample waits for closure then repairs once", %{base: base, car: car} do
    push(base, 91, %{"Odometer" => 10001.623456, "VehicleSpeed" => 30.0})
    assert {:ok, :late} = push(base, 61, %{"Odometer" => 10001.123456, "VehicleSpeed" => 60.0})

    assert Repo.one!(from e in Event, where: e.status == "late").error ==
             "repair_waiting_for_closed_drive"

    assert Repo.aggregate(Repair, :count) == 0
    finish(base)
    checkpoint = Repo.get!(Checkpoint, car.id)
    assert LateRepair.retry(base) == [{:ok, :repaired}]
    assert LateRepair.retry(base) == []
    assert Repo.aggregate(Repair, :count) == 1
    assert Repo.get!(Checkpoint, car.id) == checkpoint
  end

  test "a late shift boundary cannot silently split an existing drive", %{base: base} do
    before = finish(base)
    count = Repo.aggregate(Log.Position, :count)
    assert {:ok, :late} = push(base, 61, %{"Gear" => "ShiftStateP", "Odometer" => 10001.123456})

    assert Repo.one!(from e in Event, where: e.status == "late").error ==
             "repair_state_transition_requires_replay"

    assert Repo.get!(Log.Drive, before.id) == before
    assert Repo.aggregate(Log.Position, :count) == count
    assert Repo.aggregate(Repair, :count) == 0
  end

  test "a changed field carried into following samples requires full replay", %{base: base} do
    finish(base)
    assert {:ok, :late} = push(base, 61, %{"Odometer" => 10001.123456, "OutsideTemp" => 12.0})

    assert Repo.one!(from e in Event, where: e.status == "late").error ==
             "repair_would_change_following_samples"

    assert Repo.aggregate(Repair, :count) == 0
  end

  test "odometer outliers and timestamp collisions remain auditable raw events", %{base: base} do
    push(base, 61, %{"Odometer" => 10001.123456})
    finish(base)
    assert {:ok, :late} = push(base, 31, %{"Odometer" => 999.0})

    assert Repo.one!(from e in Event, where: e.status == "late").error ==
             "repair_inconsistent_odometer"

    assert {:ok, :late} = push(base, 61, %{"Odometer" => 10001.5})
    assert Repo.exists?(from e in Event, where: e.error == "repair_ambiguous_timestamp")
    assert Repo.aggregate(Repair, :count) == 0
  end

  test "an audit failure rolls back the sample and recalculated drive together", %{
    base: base,
    car: car
  } do
    before = finish(base)
    count = Repo.aggregate(Log.Position, :count)

    Repo.query!(
      "CREATE FUNCTION reject_fleet_repair() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'repair audit unavailable'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER reject_fleet_repair BEFORE INSERT ON fleet_repairs FOR EACH ROW EXECUTE FUNCTION reject_fleet_repair()"
    )

    {:ok, :stored} =
      Ingest.store(
        car,
        "telemetry",
        record(car, 61, %{"Odometer" => 10001.123456, "VehicleSpeed" => 60.0})
      )

    assert_raise Postgrex.Error, ~r/repair audit unavailable/, fn -> step(base) end
    assert Repo.aggregate(Log.Position, :count) == count
    assert Repo.get!(Log.Drive, before.id) == before
    assert Repo.exists?(from e in Event, where: e.status == "pending")
  end
end
