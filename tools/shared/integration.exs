# Runs after the CI full-schema migration/copy checks, in an isolated database.
Application.load(:teslamate)
for app <- Application.spec(:teslamate, :applications), do: Application.ensure_all_started(app)
{:ok, _} = Registry.start_link(keys: :unique, name: TeslaMate.MultiTenant.Registry)
{:ok, _} = TeslaMate.Vault.start_link([])
{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: TeslaMate.PubSub)

alias TeslaMate.{Repo, Log}
alias TeslaMate.MultiTenant.{Tenant, TenantState, TenantContext}
alias TeslaMate.Fleet.{Ingest, Projector, Event}
import TeslaMate.FleetFixture

{:ok, _} = Repo.start_link(pool: DBConnection.ConnectionPool, pool_size: 2)
System.put_env("TESLAMATE_MULTI_TENANT", "true")
System.put_env("TESLAMATE_SHARED_DATABASE", "true")
copy_schema = "tenant_" <> (Base.encode16(:crypto.hash(:sha256, "full-copy-check"), case: :lower) |> String.slice(0, 32))

for {schema, vin} <- [{"tenant_migration_check", "LRW00000000000001"}, {copy_schema, "LRW00000000000002"}] do
  {:ok, tenant} = Tenant.new(%{id: schema, status: "active", database: %{host: "localhost", username: "postgres", password: "postgres", name: "teslamate_test", schema: schema}, vehicles: [%{id: "9001", vin: vin, status: "active"}]})
  {:ok, _} = TenantState.start_link(tenant: tenant)
  TenantContext.run(schema, fn ->
    {:ok, car} = Log.create_car(%{eid: 9001, vid: 9002, vin: vin})
    true = car.id == 1
    base = %TeslaMate.Vehicles.Vehicle.Data{car: car, fleet?: true, import?: true, deps: %{log: Log, locations: TeslaMate.Locations}}
    {:ok, :stored} = Ingest.store(car, "snapshot", snapshot(car))
    {:ok, {"projected", :online, _}} = Projector.step(base, reorder_seconds: 0)
    for {seconds, fields} <- [{1, %{"Gear" => "ShiftStateD", "VehicleSpeed" => 30.0}}, {61, %{"Odometer" => 10001.123456}}, {121, %{"Gear" => "ShiftStateP", "Odometer" => 10002.123456, "VehicleSpeed" => 0.0}}] do
      event = record(car, seconds, fields)
      {:ok, :stored} = Ingest.ingest(schema, event)
      {:ok, :duplicate} = Ingest.ingest(schema, event)
      {:ok, {"projected", _, _}} = Projector.step(base, reorder_seconds: 0)
    end
    [drive] = Repo.all(Log.Drive)
    true = drive.id == 1
    true = abs(drive.distance - 3.218688) < 0.000001
    true = drive.start_date == ~U[2026-01-01 00:00:01.000000Z]
    true = drive.end_date == ~U[2026-01-01 00:02:01.000000Z]
    true = Repo.aggregate(Event, :count) == 4
    [stored] = Repo.all(Log.Car)
    true = stored.vin == vin
    {:online, _} = Projector.restore(base)
  end)
end
IO.puts("Shared Fleet projection: two tenants, identical IDs, independent drives and restart checkpoints verified")
