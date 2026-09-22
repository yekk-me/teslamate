defmodule TeslaMate.Fleet.Worker do
  @moduledoc "Tenant-local single writer for durable Fleet samples. REST uses the same inbox."
  use GenServer
  require Logger
  alias TeslaMate.Fleet.{Ingest, Projector}
  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Vehicles.Vehicle.Summary

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.fetch!(opts, :car).id},
      start: {__MODULE__, :start_link, [opts]}
    }

  @impl true
  def init(opts) do
    {:ok, _, base, _} = Vehicle.init(Keyword.put(opts, :fleet?, true))
    {state, data} = Projector.restore(base)
    send(self(), :poll)
    send(self(), :drain)
    {:ok, %{base: base, data: data, state: state, task: nil, healthy?: false}}
  end

  @impl true
  def handle_call(:summary, _from, s), do: {:reply, summary(s), s}
  def handle_call(:busy?, _from, s), do: {:reply, s.task != nil, s}
  def handle_call(:resume_logging, _from, s), do: {:reply, :ok, s}

  def handle_call(:suspend_logging, _from, s),
    do: {:reply, {:error, :fleet_push_does_not_poll_continuously}, s}

  @impl true
  def handle_info(:drain, s) do
    s =
      Enum.reduce_while(1..100, s, fn _, s ->
        case Projector.step(s.base) do
          {:ok, {"projected", state, data}} ->
            {:cont, %{s | state: state, data: data, healthy?: true}}

          {:ok, :empty} ->
            {:halt, s}

          {:ok, _} ->
            {:cont, %{s | healthy?: false}}

          {:error, _} ->
            Logger.error("Fleet projection blocked; durable inbox retained",
              car_id: s.base.car.id
            )

            {:halt, %{s | healthy?: false}}
        end
      end)

    Phoenix.PubSub.broadcast(
      TeslaMate.PubSub,
      "#{Vehicle}/summary/#{s.data.tenant_id}/#{s.data.car.id}",
      summary(s)
    )

    Process.send_after(self(), :drain, 1000)
    {:noreply, s}
  end

  def handle_info(:poll, %{task: nil} = s) do
    api = s.base.deps.api
    vin = s.base.car.vin

    task =
      TeslaMate.MultiTenant.TenantTask.async(fn ->
        # The metadata endpoint does not wake a sleeping vehicle. Never send wake_up.
        try do
          case Core.Dependency.call(api, :get_vehicle, [vin]) do
            {:ok, %TeslaApi.Vehicle{state: "online"}} ->
              Core.Dependency.call(api, :get_vehicle_with_state, [vin])

            result ->
              result
          end
        rescue
          _ -> {:error, :fleet_rest_failure}
        catch
          :exit, _ -> {:error, :fleet_rest_failure}
        end
      end)

    {:noreply, %{s | task: task}}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])

    saved =
      case result do
        {:ok, %TeslaApi.Vehicle{state: "online"} = v} ->
          payload = to_map(v) |> Map.put("option_codes", Enum.join(v.option_codes || [], ","))
          Ingest.store(s.base.car, "snapshot", payload)

        {:ok, %TeslaApi.Vehicle{state: state}} when state in ~w(asleep offline) ->
          Ingest.store(s.base.car, "status", %{
            "vin" => s.base.car.vin,
            "state" => state,
            "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
          })

        _ ->
          {:error, :unavailable}
      end

    delay =
      case result do
        {:error, :too_many_request, seconds} when is_integer(seconds) ->
          max(poll_interval(), seconds * 1000)

        _ ->
          poll_interval()
      end

    Process.send_after(self(), :poll, delay)
    {:noreply, %{s | task: nil, healthy?: s.healthy? and match?({:ok, _}, saved)}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = s) do
    Process.send_after(self(), :poll, poll_interval())
    {:noreply, %{s | task: nil, healthy?: false}}
  end

  def handle_info(%TeslaMate.Settings.CarSettings{} = settings, s) do
    car = %{s.base.car | settings: settings}
    {:noreply, %{s | base: %{s.base | car: car}, data: %{s.data | car: car}}}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp poll_interval,
    do:
      String.to_integer(System.get_env("TESLA_FLEET_RECONCILE_SECONDS", "300"))
      |> max(30)
      |> then(&(&1 * 1000))

  defp summary(s) do
    Summary.into(s.data.last_response, %{
      state: s.state,
      healthy?: s.healthy?,
      car: s.data.car,
      since: s.data.last_state_change,
      elevation: s.data.elevation,
      geofence: s.data.geofence
    })
  end

  defp to_map(%{__struct__: _} = v), do: v |> Map.from_struct() |> to_map()
  defp to_map(v) when is_map(v), do: Map.new(v, fn {k, v} -> {to_string(k), to_map(v)} end)
  defp to_map(v) when is_list(v), do: Enum.map(v, &to_map/1)
  defp to_map(v), do: v
end
