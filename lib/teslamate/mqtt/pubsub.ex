defmodule TeslaMate.Mqtt.PubSub do
  use Supervisor

  alias __MODULE__.VehicleSubscriber
  alias TeslaMate.Vehicles

  # API

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    vehicles = Keyword.get(opts, :vehicles, Vehicles)
    publisher = Keyword.get(opts, :publisher, TeslaMate.Mqtt.Publisher)

    children =
      opts
      |> car_ids(vehicles)
      |> Enum.map(
        &{VehicleSubscriber,
         Keyword.merge(opts, car_id: &1, deps_vehicles: vehicles, deps_publisher: publisher)}
      )

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp car_ids(opts, vehicles) do
    case Keyword.get(opts, :car_ids) do
      car_ids when is_list(car_ids) ->
        car_ids

      _ ->
        vehicles
        |> Core.Dependency.call(:list)
        |> Enum.map(& &1.car.id)
    end
  end
end
