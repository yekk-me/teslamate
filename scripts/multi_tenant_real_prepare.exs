defmodule MultiTenantRealPrepare do
  @tenant_id System.get_env("SMOKE_TENANT_ID", "tenant-real-a")
  @tenant_db System.get_env("SMOKE_TENANT_DATABASE", "teslamate_mt_real_a")
  @tenant_namespace System.get_env("SMOKE_MQTT_NAMESPACE", "tenant-real-a")

  def run do
    Logger.configure(level: :warning)
    start_dependencies()

    auth =
      %TeslaApi.Auth{
        token: System.fetch_env!("TESLA_ACCESS_TOKEN"),
        refresh_token: System.fetch_env!("TESLA_REFRESH_TOKEN")
      }
      |> refresh_tokens!()

    save_tokens!(auth)
    vehicle = discover_vehicle!(auth)
    write_tenant_directory!(vehicle)
  end

  defp start_dependencies do
    for app <- [:logger, :crypto, :ssl, :postgrex, :ecto, :ecto_sql, :cloak, :cloak_ecto, :jason] do
      {:ok, _apps} = Application.ensure_all_started(app)
    end

    {:ok, _vault} =
      TeslaMate.Vault.start_link(Application.fetch_env!(:teslamate, TeslaMate.Vault))

    {:ok, _repo} = TeslaMate.Repo.start_link()
    {:ok, _finch} = Finch.start_link(name: TeslaMate.HTTP, pools: TeslaMate.HTTP.pools())
  end

  defp refresh_tokens!(auth) do
    case TeslaApi.Auth.refresh(auth) do
      {:ok, refreshed_auth} ->
        refreshed_auth

      {:error, reason} ->
        Mix.raise("Tesla token refresh failed: #{inspect(reason)}")
    end
  end

  defp save_tokens!(auth) do
    :ok = TeslaMate.Auth.save(auth)
    Mix.shell().info("Seeded encrypted Tesla tokens into #{@tenant_db}")
  end

  defp discover_vehicle!(auth) do
    case TeslaApi.Vehicle.list(auth) do
      {:ok, vehicles} ->
        vehicles
        |> select_vehicle()
        |> case do
          nil -> Mix.raise("No Tesla vehicle found for the supplied token")
          vehicle -> vehicle
        end

      {:error, reason} ->
        Mix.raise("Tesla vehicle discovery failed: #{inspect(reason)}")
    end
  end

  defp select_vehicle(vehicles) do
    case System.get_env("TESLA_VIN") do
      nil -> List.first(vehicles)
      vin -> Enum.find(vehicles, &(&1.vin == vin))
    end
  end

  defp write_tenant_directory!(vehicle) do
    path = System.fetch_env!("TENANT_DIRECTORY_PATH")

    database =
      %{
        host: System.fetch_env!("TENANT_DATABASE_HOST"),
        port: System.fetch_env!("TENANT_DATABASE_PORT") |> String.to_integer(),
        username: System.fetch_env!("TENANT_DATABASE_USER"),
        password: System.fetch_env!("TENANT_DATABASE_PASS"),
        name: @tenant_db,
        pool_size: 1,
        ssl: false
      }
      |> maybe_put_pooler()

    directory = %{
      tenants: [
        %{
          id: @tenant_id,
          status: "active",
          database: database,
          mqtt: %{
            host: System.fetch_env!("TENANT_MQTT_HOST"),
            port: System.fetch_env!("TENANT_MQTT_PORT") |> String.to_integer(),
            namespace: @tenant_namespace
          },
          entitlements: %{enabled: true, logging: true},
          limits: %{
            max_vehicles: 1,
            max_active_vehicles: 1,
            tesla_api_requests_per_minute: 30,
            mqtt_publishes_per_minute: 300
          },
          vehicles: [
            %{
              id: to_string(vehicle.id),
              eid: to_string(vehicle.id),
              vid: to_string(vehicle.vehicle_id),
              vin: vehicle.vin,
              display_name: vehicle.display_name || "Tesla",
              status: "active"
            }
          ]
        }
      ]
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(directory, pretty: true))
    Mix.shell().info("Wrote tenant directory to #{path}")
    Mix.shell().info("Selected vehicle VIN suffix: #{String.slice(vehicle.vin || "", -6, 6)}")
  end

  defp maybe_put_pooler(database) do
    case System.get_env("TENANT_DATABASE_POOLER") do
      nil -> database
      "" -> database
      pooler -> Map.put(database, :pooler, pooler)
    end
  end
end

MultiTenantRealPrepare.run()
