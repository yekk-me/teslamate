defmodule TeslaMate.Fleet.Decoder do
  @moduledoc "Converts official decoded protobuf deltas to Fleet vehicle_data fields without changing units."

  @fields %{
    "VehicleSpeed" => {"drive_state", "speed", :number},
    "GpsHeading" => {"drive_state", "heading", :number},
    "Odometer" => {"vehicle_state", "odometer", :number},
    "Soc" => {"charge_state", "usable_battery_level", :integer},
    "BatteryLevel" => {"charge_state", "battery_level", :integer},
    "IdealBatteryRange" => {"charge_state", "ideal_battery_range", :number},
    "EstBatteryRange" => {"charge_state", "est_battery_range", :number},
    "RatedRange" => {"charge_state", "battery_range", :number},
    "DCChargingEnergyIn" => {"charge_state", "charge_energy_added", :number},
    "ChargeAmps" => {"charge_state", "charger_actual_current", :integer},
    "ChargerVoltage" => {"charge_state", "charger_voltage", :integer},
    "ChargerPhases" => {"charge_state", "charger_phases", :integer},
    "ChargeLimitSoc" => {"charge_state", "charge_limit_soc", :integer},
    "ChargeCurrentRequest" => {"charge_state", "charge_current_request", :integer},
    "ChargeCurrentRequestMax" => {"charge_state", "charge_current_request_max", :integer},
    "FastChargerPresent" => {"charge_state", "fast_charger_present", :boolean},
    "BatteryHeaterOn" => {"charge_state", "battery_heater_on", :boolean},
    "NotEnoughPowerToHeat" => {"charge_state", "not_enough_power_to_heat", :boolean},
    "ChargePortDoorOpen" => {"charge_state", "charge_port_door_open", :boolean},
    "EstimatedHoursToChargeTermination" => {"charge_state", "time_to_full_charge", :number},
    "InsideTemp" => {"climate_state", "inside_temp", :number},
    "OutsideTemp" => {"climate_state", "outside_temp", :number},
    "HvacFanStatus" => {"climate_state", "fan_status", :integer},
    "HvacLeftTemperatureRequest" => {"climate_state", "driver_temp_setting", :number},
    "HvacRightTemperatureRequest" => {"climate_state", "passenger_temp_setting", :number},
    "RearDefrostEnabled" => {"climate_state", "is_rear_defroster_on", :boolean},
    "Locked" => {"vehicle_state", "locked", :boolean},
    "DriverSeatOccupied" => {"vehicle_state", "is_user_present", :boolean},
    "Version" => {"vehicle_state", "car_version", :string},
    "VehicleName" => {"vehicle_state", "vehicle_name", :string},
    "TpmsPressureFl" => {"vehicle_state", "tpms_pressure_fl", :number},
    "TpmsPressureFr" => {"vehicle_state", "tpms_pressure_fr", :number},
    "TpmsPressureRl" => {"vehicle_state", "tpms_pressure_rl", :number},
    "TpmsPressureRr" => {"vehicle_state", "tpms_pressure_rr", :number},
    "Trim" => {"vehicle_config", "trim_badging", :string},
    "ExteriorColor" => {"vehicle_config", "exterior_color", :string},
    "WheelType" => {"vehicle_config", "wheel_type", :string}
  }
  @groups ~w(drive_state charge_state climate_state vehicle_state vehicle_config)

  def merge(snapshot, %{"data" => data}, at) do
    ts = DateTime.to_unix(at, :millisecond)

    snapshot =
      Enum.reduce(@groups, snapshot, fn group, acc ->
        Map.update(acc, group, %{}, &(&1 || %{}))
      end)

    snapshot = reset_charge_session(snapshot, data)

    snapshot =
      Enum.reduce(data, snapshot, fn %{"key" => key, "value" => encoded}, acc ->
        value = value(encoded)
        acc = put_in(acc, [Access.key("_signals", %{}), key], value)
        acc = put_in(acc, [Access.key("_signal_times", %{}), key], ts)

        case @fields[key] do
          {group, field, type} -> put_in(acc, [group, field], cast(value, type))
          nil -> special(acc, key, value)
        end
      end)

    # AC energy is charger-side. Only DCChargingEnergyIn is equivalent to battery energy added.
    fast = get_in(snapshot, ["charge_state", "fast_charger_present"])

    power =
      case fast do
        true -> get_in(snapshot, ["_signals", "DCChargingPower"])
        false -> get_in(snapshot, ["_signals", "ACChargingPower"])
        nil -> nil
      end

    snapshot =
      cond do
        is_number(power) ->
          put_in(snapshot, ["charge_state", "charger_power"], round(power))

        Map.has_key?(
          snapshot["_signals"] || %{},
          if(fast, do: "DCChargingPower", else: "ACChargingPower")
        ) ->
          put_in(snapshot, ["charge_state", "charger_power"], nil)

        true ->
          snapshot
      end

    snapshot
    |> put_in(["drive_state", "power"], nil)
    |> Map.put("state", "online")
    |> then(fn s ->
      Enum.reduce(@groups -- ["vehicle_config"], s, fn group, acc ->
        put_in(acc, [group, "timestamp"], ts)
      end)
    end)
  end

  def ready?(s) do
    numeric = [
      ["drive_state", "latitude"],
      ["drive_state", "longitude"],
      ["vehicle_state", "odometer"],
      ["charge_state", "battery_level"],
      ["charge_state", "ideal_battery_range"],
      ["charge_state", "battery_range"]
    ]

    Enum.all?(numeric, &is_number(get_in(s, &1))) and
      is_map(s["climate_state"]) and
      Map.has_key?(s["drive_state"] || %{}, "shift_state") and
      get_in(s, ["drive_state", "shift_state"]) in [nil, "P", "D", "N", "R"] and
      get_in(s, ["charge_state", "charging_state"]) in ~w(Disconnected NoPower Starting Charging Complete Stopped) and
      is_binary(get_in(s, ["vehicle_config", "car_type"])) and charge_ready?(s)
  end

  defp reset_charge_session(s, data) do
    charging? =
      Enum.any?(data, fn
        %{"key" => "DetailedChargeState", "value" => v} ->
          value(v) in ~w(DetailedChargeStateStarting DetailedChargeStateCharging)

        _ ->
          false
      end)

    if charging? and get_in(s, ["charge_state", "charging_state"]) not in ~w(Starting Charging) do
      s
      |> put_in(["charge_state", "charge_energy_added"], nil)
      |> put_in(["charge_state", "charger_power"], nil)
      |> Map.update(
        "_signals",
        %{},
        &Map.drop(&1, ~w(DCChargingPower ACChargingPower DCChargingEnergyIn))
      )
    else
      s
    end
  end

  defp charge_ready?(s) do
    if get_in(s, ["charge_state", "charging_state"]) in ~w(Starting Charging Complete Stopped) do
      is_number(get_in(s, ["charge_state", "charge_energy_added"])) and
        is_number(get_in(s, ["charge_state", "charger_power"]))
    else
      true
    end
  end

  defp special(s, "Location", %{"latitude" => lat, "longitude" => lon})
       when is_number(lat) and lat >= -90 and lat <= 90 and is_number(lon) and lon >= -180 and
              lon <= 180,
       do:
         s
         |> put_in(["drive_state", "latitude"], lat)
         |> put_in(["drive_state", "longitude"], lon)

  defp special(s, "Location", _),
    do: s |> put_in(["drive_state", "latitude"], nil) |> put_in(["drive_state", "longitude"], nil)

  defp special(s, "Gear", v) do
    gear =
      case v do
        "ShiftState" <> g when g in ~w(P R N D) -> g
        g when g in ~w(P R N D) -> g
        _ -> "unknown"
      end

    put_in(s, ["drive_state", "shift_state"], gear)
  end

  defp special(s, "DetailedChargeState", v) do
    state =
      case v do
        "DetailedChargeState" <> c
        when c in ~w(Disconnected NoPower Starting Charging Complete Stopped) ->
          c

        _ ->
          "Unknown"
      end

    put_in(s, ["charge_state", "charging_state"], state)
  end

  defp special(s, "CarType", "CarType" <> type),
    do: put_in(s, ["vehicle_config", "car_type"], String.downcase(type))

  defp special(s, "CarType", v), do: put_in(s, ["vehicle_config", "car_type"], v)

  defp special(s, "HvacPower", v),
    do:
      put_in(
        s,
        ["climate_state", "is_climate_on"],
        enum_bool(
          v,
          "HvacPowerStateOff",
          ~w(HvacPowerStateOn HvacPowerStatePrecondition HvacPowerStateOverheatProtect)
        )
      )

  defp special(s, "SentryMode", v),
    do:
      put_in(
        s,
        ["vehicle_state", "sentry_mode"],
        enum_bool(
          v,
          "SentryModeStateOff",
          ~w(SentryModeStateIdle SentryModeStateArmed SentryModeStateAware SentryModeStatePanic SentryModeStateQuiet)
        )
      )

  defp special(s, _key, _v), do: s

  defp enum_bool(off, off, _), do: false
  defp enum_bool(value, _, on), do: if(value in on, do: true, else: nil)
  defp value(%{"invalid" => true}), do: nil
  defp value(encoded) when map_size(encoded) == 1, do: encoded |> Map.values() |> hd()
  defp value(_), do: nil
  defp cast(nil, _), do: nil
  defp cast(v, :number) when is_number(v), do: v

  defp cast(v, :number) when is_binary(v) do
    case Float.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp cast(v, :integer) do
    case cast(v, :number) do
      n when is_number(n) -> round(n)
      _ -> nil
    end
  end

  defp cast(v, :boolean) when is_boolean(v), do: v
  defp cast("true", :boolean), do: true
  defp cast("false", :boolean), do: false
  defp cast(v, :string) when is_binary(v), do: v
  defp cast(_, _), do: nil
end
