defmodule TeslaMate.Fleet.DecoderTest do
  use ExUnit.Case, async: true
  alias TeslaMate.Fleet.Decoder
  import TeslaMate.FleetFixture
  @car %{vin: "LRW00000000000001", eid: 1, vid: 1}
  @at ~U[2026-01-01 00:00:01Z]

  test "delta fields preserve miles, mph, coordinates, precision and omitted values" do
    decoded =
      Decoder.merge(
        snapshot(@car),
        record(@car, 1, %{
          "VehicleSpeed" => 12.3456,
          "Odometer" => 10001.123456,
          "Location" => %{"latitude" => 31.123456789, "longitude" => 121.123456789},
          "Gear" => "ShiftStateD"
        }),
        @at
      )

    assert decoded["drive_state"]["speed"] == 12.3456
    assert decoded["drive_state"]["latitude"] == 31.123456789
    assert decoded["vehicle_state"]["odometer"] == 10001.123456
    assert decoded["charge_state"]["battery_range"] == 190.0
    assert decoded["drive_state"]["power"] == nil
    assert Decoder.ready?(decoded)
  end

  test "invalid differs from omitted and unknown gear cannot end a drive" do
    invalid = Decoder.merge(snapshot(@car), record(@car, 1, %{"Location" => :invalid}), @at)
    refute Decoder.ready?(invalid)
    assert invalid["drive_state"]["latitude"] == nil

    unknown =
      Decoder.merge(snapshot(@car), record(@car, 1, %{"Gear" => "ShiftStateUnknown"}), @at)

    refute Decoder.ready?(unknown)
  end

  test "AC charger-side energy is never substituted for battery-side energy" do
    decoded =
      Decoder.merge(
        snapshot(@car),
        record(@car, 1, %{
          "DetailedChargeState" => "DetailedChargeStateCharging",
          "ACChargingEnergyIn" => 12.345,
          "DCChargingEnergyIn" => 10.123456,
          "ACChargingPower" => 7.4
        }),
        @at
      )

    assert decoded["charge_state"]["charge_energy_added"] == 10.123456
    assert decoded["charge_state"]["charger_power"] == 7
    assert decoded["_signals"]["ACChargingEnergyIn"] == 12.345
    assert Decoder.ready?(decoded)
  end

  test "new charge session cannot reuse previous session energy" do
    decoded =
      Decoder.merge(
        snapshot(@car),
        record(@car, 1, %{"DetailedChargeState" => "DetailedChargeStateCharging"}),
        @at
      )

    refute Decoder.ready?(decoded)
    assert decoded["charge_state"]["charge_energy_added"] == nil
  end
end
