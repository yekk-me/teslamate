# Isolated CI database only. Real HTTP controller, tenant repository and projector.
Application.load(:teslamate)
for app <- Application.spec(:teslamate, :applications), do: Application.ensure_all_started(app)
{:ok, _} = Registry.start_link(keys: :unique, name: TeslaMate.MultiTenant.Registry)
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: TeslaMate.PubSub)
{:ok, _} = TeslaMateWeb.Endpoint.start_link()
{:ok, _} = Plug.Cowboy.http(TeslaMateWeb.Endpoint, [], port: 14000, ip: {127, 0, 0, 1})

alias TeslaMate.{Repo, Log}
alias TeslaMate.MultiTenant.{Tenant, TenantContext, TenantState, TenantSupervisor}
alias TeslaMate.Fleet.{Ingest, Projector, Event}
opts = Application.fetch_env!(:teslamate, Repo)

{:ok, _} =
  Repo.start_link(
    Keyword.merge(opts,
      name: TenantSupervisor.repo_name("smoke"),
      pool: DBConnection.ConnectionPool
    )
  )

tenant = %Tenant{
  id: "smoke",
  database: nil,
  vehicles: [%Tenant.Vehicle{id: "9001", vin: "LRW00000000000001", status: "active"}]
}

{:ok, _} = TenantState.start_link(tenant: tenant)

base =
  TenantContext.run("smoke", fn ->
    {:ok, car} = Log.create_car(%{eid: 9001, vid: 9002, vin: "LRW00000000000001"})

    base = %TeslaMate.Vehicles.Vehicle.Data{
      car: car,
      fleet?: true,
      import?: true,
      deps: %{log: Log, locations: TeslaMate.Locations}
    }

    {:ok, :stored} = Ingest.store(car, "snapshot", TeslaMate.FleetFixture.snapshot(car))
    {:ok, {"projected", :online, _}} = Projector.step(base, reorder_seconds: 0)
    base
  end)

path = System.fetch_env!("FLEET_SMOKE_DIR")
File.write!(Path.join(path, "inbox-ready"), "ready")

Stream.repeatedly(fn ->
  TenantContext.run("smoke", fn ->
    Projector.step(base, reorder_seconds: 0)

    if File.exists?(Path.join(path, "check")) do
      import Ecto.Query

      counts =
        Repo.all(from e in Event, group_by: e.status, select: {e.status, count(e.id)})
        |> Map.new()

      if (counts["projected"] || 0) >= 4 do
        true = Repo.aggregate(Event, :count) == 4
        [drive] = Repo.all(Log.Drive)
        true = abs(drive.distance - 3.218688) < 0.000001
        true = drive.start_date == ~U[2026-01-01 00:00:01.000000Z]
        true = drive.end_date == ~U[2026-01-01 00:02:01.000000Z]
        positions = Repo.aggregate(Log.Position, :count)
        true = positions >= 3

        File.write!(
          Path.join(path, "result.tmp"),
          Jason.encode!(%{
            events: 4,
            drives: 1,
            distance_km: drive.distance,
            positions: positions,
            statuses: counts
          })
        )

        File.rename!(Path.join(path, "result.tmp"), Path.join(path, "result.json"))
      end
    end
  end)

  Process.sleep(200)
end)
|> Stream.run()
