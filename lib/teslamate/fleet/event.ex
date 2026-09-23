defmodule TeslaMate.Fleet.Event do
  use Ecto.Schema

  schema "fleet_events" do
    belongs_to :car, TeslaMate.Log.Car
    field :source, :string
    field :event_key, :string
    field :recorded_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec
    field :payload, :map
    field :status, :string, default: "pending"
    field :error, :string
  end
end

defmodule TeslaMate.Fleet.Checkpoint do
  use Ecto.Schema
  @primary_key {:car_id, :id, autogenerate: false}
  schema "fleet_checkpoints" do
    field :version, :integer, default: 1
    field :snapshot, :map, default: %{}
    field :logger_state, :binary
    field :recorded_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end

defmodule TeslaMate.Fleet.Repair do
  use Ecto.Schema

  schema "fleet_repairs" do
    belongs_to :event, TeslaMate.Fleet.Event
    belongs_to :drive, TeslaMate.Log.Drive
    belongs_to :position, TeslaMate.Log.Position
    field :before_metrics, :map
    field :after_metrics, :map
    field :inserted_at, :utc_datetime_usec
  end
end
