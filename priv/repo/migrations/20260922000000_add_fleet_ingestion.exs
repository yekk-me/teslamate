defmodule TeslaMate.Repo.Migrations.AddFleetIngestion do
  use Ecto.Migration

  defp private_prefix,
    do: if(prefix() in [nil, "public"], do: "private", else: prefix() <> "_private")

  def change do
    # Ecto forbids a second prefix when the migrator itself is scoped. The
    # private schema is pre-created by provisioning; address it explicitly.
    private = "\"" <> String.replace(private_prefix(), "\"", "\"\"") <> "\""

    execute(
      "ALTER TABLE #{private}.tokens ADD COLUMN provider text NOT NULL DEFAULT 'owner'",
      "ALTER TABLE #{private}.tokens DROP COLUMN provider"
    )

    execute(
      "CREATE TABLE #{private}.fleet_oauth_states (digest bytea PRIMARY KEY, expires_at timestamp(6) NOT NULL)",
      "DROP TABLE #{private}.fleet_oauth_states"
    )

    create table(:fleet_events) do
      add :car_id, references(:cars, on_delete: :delete_all), null: false
      add :source, :text, null: false
      add :event_key, :text, null: false
      add :recorded_at, :utc_datetime_usec, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :payload, :map, null: false
      add :status, :text, null: false, default: "pending"
      add :error, :text
    end

    create unique_index(:fleet_events, [:car_id, :event_key])
    create index(:fleet_events, [:car_id, :status, :recorded_at, :id])

    create table(:fleet_checkpoints, primary_key: false) do
      add :car_id, references(:cars, on_delete: :delete_all), primary_key: true
      add :version, :integer, null: false, default: 1
      add :snapshot, :map, null: false, default: %{}
      add :logger_state, :binary
      add :recorded_at, :utc_datetime_usec
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
