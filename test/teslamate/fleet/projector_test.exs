defmodule TeslaMate.Fleet.ProjectorTest do
  use TeslaMate.DataCase
  import TeslaMate.FleetFixture
  alias TeslaMate.{Repo, Log}
  alias TeslaMate.Fleet.{Ingest, Projector, Event, Checkpoint}
  alias TeslaMate.Vehicles.Vehicle.Data

  defmodule FailingLog do
    defdelegate update_car(car, attrs, opts), to: TeslaMate.Log
    defdelegate start_state(car, state, opts), to: TeslaMate.Log
    defdelegate get_latest_update(car), to: TeslaMate.Log
    defdelegate insert_missed_update(car, version, opts), to: TeslaMate.Log
    def insert_position(_, _), do: {:error, :forced_failure}
  end

  setup do
    {:ok, car} = Log.create_car(%{eid: 9001, vid: 9002, vin: "LRW00000000000001"})

    base = %Data{
      car: car,
      fleet?: true,
      import?: true,
      deps: %{log: Log, locations: TeslaMate.Locations}
    }

    %{car: car, base: base}
  end

  defp step(base), do: Projector.step(base, reorder_seconds: 0)

  test "snapshots and telemetry share the drive calculator, survive restart and deduplicate", %{
    car: car,
    base: base
  } do
    assert {:ok, :stored} = Ingest.store(car, "snapshot", snapshot(car))
    assert {:ok, {"projected", :online, _}} = step(base)
    r1 = record(car, 1, %{"Gear" => "ShiftStateD", "VehicleSpeed" => 30.0})

    r2 =
      record(car, 61, %{
        "Odometer" => 10001.123456,
        "IdealBatteryRange" => 199.0,
        "RatedRange" => 189.0
      })

    r3 =
      record(car, 121, %{
        "Gear" => "ShiftStateP",
        "Odometer" => 10002.123456,
        "VehicleSpeed" => 0.0,
        "IdealBatteryRange" => 198.0,
        "RatedRange" => 188.0
      })

    for r <- [r2, r1, r3], do: assert({:ok, :stored} = Ingest.store(car, "telemetry", r))
    assert {:ok, {"projected", {:driving, :available, drive}, _}} = step(base)
    assert {{:driving, :available, restored}, restored_data} = Projector.restore(base)
    assert restored_data.car.model == "3"
    assert restored.id == drive.id
    assert drive.start_date == ~U[2026-01-01 00:00:01.000000Z]
    assert {:ok, {"projected", {:driving, :available, _}, _}} = step(base)
    assert {:ok, {"projected", :online, _}} = step(base)
    closed = Repo.get!(Log.Drive, drive.id)
    assert_in_delta closed.distance, 3.218688, 0.000001
    assert_in_delta closed.duration_min, 2, 0.001
    assert closed.end_date == ~U[2026-01-01 00:02:01.000000Z]
    count = Repo.aggregate(Log.Position, :count)
    assert {:ok, :duplicate} = Ingest.store(car, "telemetry", Map.put(r3, "isResend", true))
    assert {:ok, :empty} = step(base)
    assert Repo.aggregate(Log.Position, :count) == count
  end

  test "equivalent REST samples and telemetry produce identical drive and position metrics", %{car: car, base: base} do
    {:ok, reference} = Log.create_car(%{eid: 9101, vid: 9102, vin: "LRW00000000000002"})
    reference_base = %{base | car: reference}
    samples = [{0, "P", 0, 10000.123456, 200.0}, {1, "D", 30, 10000.123456, 200.0},
      {61, "D", 30, 10001.123456, 199.0}, {121, "P", 0, 10002.123456, 198.0}]
    for {sec, gear, speed, odometer, range} <- samples do
      rest = snapshot(reference, sec)
        |> put_in(["drive_state", "shift_state"], gear)
        |> put_in(["drive_state", "speed"], speed)
        |> put_in(["vehicle_state", "odometer"], odometer)
        |> put_in(["charge_state", "ideal_battery_range"], range)
        |> put_in(["charge_state", "battery_range"], range - 10)
      assert {:ok, :stored} = Ingest.store(reference, "snapshot", rest)
      assert {:ok, {"projected", _, _}} = step(reference_base)
      if sec == 0 do
        Ingest.store(car, "snapshot", snapshot(car))
      else
        Ingest.store(car, "telemetry", record(car, sec, %{"Gear" => "ShiftState" <> gear,
          "VehicleSpeed" => speed, "Odometer" => odometer,
          "IdealBatteryRange" => range, "RatedRange" => range - 10}))
      end
      assert {:ok, {"projected", _, _}} = step(base)
    end
    keys = [:start_date, :end_date, :distance, :duration_min, :speed_max, :speed_avg,
      :start_ideal_range_km, :end_ideal_range_km, :start_rated_range_km, :end_rated_range_km]
    actual = Repo.one!(from d in Log.Drive, where: d.car_id == ^car.id)
    expected = Repo.one!(from d in Log.Drive, where: d.car_id == ^reference.id)
    assert Map.take(actual, keys) == Map.take(expected, keys)
    position_keys = [:date, :latitude, :longitude, :speed, :odometer, :battery_level,
      :usable_battery_level, :ideal_battery_range_km, :rated_battery_range_km, :outside_temp]
    positions = fn car_id ->
      Repo.all(from p in Log.Position, where: p.car_id == ^car_id, order_by: [p.date, p.id])
      |> Enum.map(&Map.take(&1, position_keys))
    end
    assert positions.(car.id) == positions.(reference.id)
  end

  test "vehicle microseconds survive projection into legacy position dates", %{car: car, base: base} do
    Ingest.store(car, "snapshot", snapshot(car))
    step(base)
    at = ~U[2026-01-01 00:00:01.123456Z]
    r = record(car, 1, %{"Gear" => "ShiftStateD"}) |> Map.put("createdAt", DateTime.to_iso8601(at))
    Ingest.store(car, "telemetry", r)
    assert {:ok, {"projected", {:driving, :available, drive}, _}} = step(base)
    assert Repo.one!(from p in Log.Position, where: p.drive_id == ^drive.id).date == at
  end

  test "unrelated signal changes do not bias driving sample averages", %{car: car, base: base} do
    Ingest.store(car, "snapshot", snapshot(car))
    step(base)
    Ingest.store(car, "telemetry", record(car, 1, %{"Gear" => "ShiftStateD", "VehicleSpeed" => 30.0}))
    step(base)
    count = Repo.aggregate(Log.Position, :count)
    Ingest.store(car, "telemetry", record(car, 2, %{"OutsideTemp" => 23.75, "Locked" => true}))
    assert {:ok, {"cached", {:driving, :available, _}, data}} = step(base)
    assert data.last_response.climate_state.outside_temp == 23.75
    assert Repo.aggregate(Log.Position, :count) == count
  end

  test "AC charge completion keeps battery energy and the original calculation", %{
    car: car,
    base: base
  } do
    {:ok, :stored} = Ingest.store(car, "snapshot", snapshot(car))
    step(base)

    for {sec, state, energy, range} <- [
          {1, "Charging", 0.0, 200.0},
          {1801, "Charging", 5.0, 220.0},
          {3601, "Complete", 10.0, 240.0}
        ] do
      r =
        record(car, sec, %{
          "DetailedChargeState" => "DetailedChargeState" <> state,
          "DCChargingEnergyIn" => energy,
          "ACChargingEnergyIn" => energy * 1.15,
          "ACChargingPower" => 7.0,
          "IdealBatteryRange" => range,
          "RatedRange" => range - 10
        })

      assert {:ok, :stored} = Ingest.store(car, "telemetry", r)
      assert {:ok, {"projected", _, _}} = step(base)
    end

    [charge] = Repo.all(Log.ChargingProcess)
    assert Decimal.to_float(charge.charge_energy_added) == 10.0
    assert charge.duration_min == 60.0
    assert Repo.aggregate(Log.Charge, :count) == 3
  end

  test "another tenant cannot route an assigned vehicle into this database", %{car: car} do
    if is_nil(Process.whereis(TeslaMate.MultiTenant.Registry)) do
      start_supervised!({Registry, keys: :unique, name: TeslaMate.MultiTenant.Registry})
    end
    tenant = %TeslaMate.MultiTenant.Tenant{id: "fleet-other-tenant", database: nil,
      vehicles: [%TeslaMate.MultiTenant.Tenant.Vehicle{id: "other", vin: "OTHER-VIN", status: "active"}]}
    start_supervised!({TeslaMate.MultiTenant.TenantState, tenant: tenant})
    assert {:error, :vehicle_not_assigned} = Ingest.ingest(tenant.id, record(car, 0, %{"Gear" => "ShiftStateD"}))
    assert Repo.aggregate(Event, :count) == 0
  end

  test "malformed and cross-VIN payloads are rejected before persistence", %{car: car} do
    r = record(car, 0, %{"Gear" => "ShiftStateP"})

    assert {:error, :invalid_payload} =
             Ingest.store(car, "telemetry", %{r | "vin" => "another-car"})

    assert {:error, :invalid_payload} = Ingest.store(car, "telemetry", %{r | "data" => [42]})
    assert Repo.aggregate(Event, :count) == 0
  end

  test "late samples are retained without moving the checkpoint backward", %{car: car, base: base} do
    Ingest.store(car, "snapshot", snapshot(car, 20))
    step(base)
    Ingest.store(car, "telemetry", record(car, 1, %{"Gear" => "ShiftStateD"}))
    assert {:ok, :late} = step(base)
    assert Repo.get!(Checkpoint, car.id).recorded_at == ~U[2026-01-01 00:00:20.000000Z]
    assert Repo.one!(from e in Event, where: e.status == "late").payload["data"] != []
    assert Repo.aggregate(Log.Drive, :count) == 0
  end

  test "a failed write rolls back inbox progress and all derived records", %{car: car, base: base} do
    Ingest.store(car, "snapshot", snapshot(car))
    failing = %{base | deps: Map.put(base.deps, :log, __MODULE__.FailingLog)}
    assert_raise MatchError, fn -> step(failing) end
    assert Repo.aggregate(Log.Position, :count) == 0
    assert Repo.one!(Event).status == "pending"
    assert Repo.get(Checkpoint, car.id) == nil
  end
end
