defmodule TeslaMate.FleetFixture do
  def snapshot(car, seconds \\ 0) do
    at = DateTime.add(~U[2026-01-01 00:00:00Z], seconds)
    ts = DateTime.to_unix(at, :millisecond)
    %{"id" => car.eid, "vehicle_id" => car.vid, "vin" => car.vin, "state" => "online",
      "drive_state" => %{"timestamp" => ts, "latitude" => 31.230416, "longitude" => 121.473701,
        "shift_state" => "P", "speed" => 0, "power" => 0},
      "charge_state" => %{"timestamp" => ts, "charging_state" => "Disconnected", "battery_level" => 80,
        "usable_battery_level" => 79, "ideal_battery_range" => 200.0, "battery_range" => 190.0,
        "charge_energy_added" => 0.0, "charger_power" => 0, "fast_charger_present" => false},
      "vehicle_state" => %{"timestamp" => ts, "odometer" => 10000.123456, "car_version" => "2026.1.0"},
      "climate_state" => %{"timestamp" => ts, "outside_temp" => 22.5},
      "vehicle_config" => %{"car_type" => "model3"}}
  end

  def record(car, seconds, fields) do
    %{"vin" => car.vin, "createdAt" => DateTime.to_iso8601(DateTime.add(~U[2026-01-01 00:00:00Z], seconds)),
      "data" => Enum.map(fields, fn {k, v} -> %{"key" => k, "value" => encoded(v)} end)}
  end
  defp encoded(:invalid), do: %{"invalid" => true}
  defp encoded(v) when is_map(v), do: %{"locationValue" => v}
  defp encoded(v) when is_boolean(v), do: %{"booleanValue" => v}
  defp encoded(v) when is_number(v), do: %{"doubleValue" => v}
  defp encoded("ShiftState" <> _ = v), do: %{"shiftStateValue" => v}
  defp encoded("DetailedChargeState" <> _ = v), do: %{"detailedChargeStateValue" => v}
  defp encoded(v), do: %{"stringValue" => v}
end
