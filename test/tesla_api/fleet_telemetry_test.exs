defmodule TeslaApi.FleetTelemetryTest do
  use ExUnit.Case
  import Mock
  alias TeslaApi.{FleetTelemetry, Auth, Error}

  setup do
    path = Path.join(System.tmp_dir!(), "fleet-config-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        hostname: "telemetry.example",
        ca: "-----BEGIN CERTIFICATE-----",
        fields: %{Location: %{interval_seconds: 1}}
      })
    )

    values = %{
      "TESLA_FLEET_COMMAND_PROXY" => "https://fleet-command:4443",
      "TESLA_FLEET_VEHICLE_CONFIG_FILE" => path
    }

    previous = Map.new(values, fn {k, _} -> {k, System.get_env(k)} end)
    System.put_env(values)

    on_exit(fn ->
      File.rm(path)

      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)
    end)

    :ok
  end

  test "configuration is server-owned and signed via the trusted proxy" do
    with_mock Tesla, [:passthrough],
      request: fn _, args ->
        assert args[:url] == "https://fleet-command:4443/api/1/vehicles/fleet_telemetry_config"
        assert args[:body]["vins"] == ["LRW00000000000001"]
        assert args[:body]["config"]["hostname"] == "telemetry.example"

        {:ok,
         %Tesla.Env{
           status: 200,
           body: %{"response" => %{"updated_vehicles" => 1, "skipped_vehicles" => %{}}}
         }}
      end do
      assert {:ok, %{"updated_vehicles" => 1}} =
               FleetTelemetry.run(%Auth{token: "secret"}, "LRW00000000000001", :configure)
    end
  end

  test "skipped vehicles and unsafe proxy URLs are failures" do
    with_mock Tesla, [:passthrough],
      request: fn _, _ ->
        {:ok,
         %Tesla.Env{
           status: 200,
           body: %{"response" => %{"skipped_vehicles" => %{"missing_key" => ["VIN"]}}}
         }}
      end do
      assert {:error, %Error{reason: :vehicle_configuration_skipped}} =
               FleetTelemetry.run(%Auth{token: "secret"}, "VIN", :configure)
    end

    for url <- [
          "http://fleet-command",
          "https://user:password@fleet-command",
          "https://fleet-command/path",
          "https://fleet-command?target=other"
        ] do
      System.put_env("TESLA_FLEET_COMMAND_PROXY", url)
      assert {:error, %Error{reason: :invalid_command_proxy}} = FleetTelemetry.proxy_url()
    end
  end

  test "status uses China API and never leaks failing response or token" do
    with_mock Tesla, [:passthrough],
      request: fn _, args ->
        assert args[:url] ==
                 TeslaApi.Fleet.api_url() <> "/api/1/vehicles/VIN/fleet_telemetry_config"

        {:ok, %Tesla.Env{status: 403, body: "sensitive"}}
      end do
      assert {:error, error} = FleetTelemetry.run(%Auth{token: "secret"}, "VIN", :status)
      refute inspect(error) =~ "sensitive"
      refute inspect(error) =~ "secret"
    end
  end
end
