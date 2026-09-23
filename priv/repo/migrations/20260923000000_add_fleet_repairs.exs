defmodule TeslaMate.Repo.Migrations.AddFleetRepairs do
  use Ecto.Migration

  def change do
    create table(:fleet_repairs) do
      add :event_id, references(:fleet_events, on_delete: :delete_all), null: false
      add :drive_id, references(:drives, on_delete: :nilify_all)
      add :position_id, references(:positions, on_delete: :nilify_all)
      add :before_metrics, :map, null: false
      add :after_metrics, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:fleet_repairs, [:event_id])
    create index(:fleet_events, [:car_id, :recorded_at, :id])
  end
end
