defmodule TeslaMate.Repair do
  use GenServer

  require Logger
  import Ecto.Query

  alias TeslaMate.Log.{Drive, Position, ChargingProcess}
  alias TeslaMate.Locations.Address
  alias TeslaMate.{Repo, Locations}

  defmodule State do
    defstruct [:limit, :fuse_name]
  end

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def trigger_run(name \\ __MODULE__) do
    GenServer.cast(name, :repair)
  end

  @impl true
  def init(opts) do
    tenant_id = Keyword.get(opts, :tenant_id)

    if is_binary(tenant_id) do
      TeslaMate.MultiTenant.TenantContext.put(tenant_id)
    end

    {:ok, _ref} =
      opts
      |> Keyword.get_lazy(:interval, fn -> :timer.hours(1) end)
      |> :timer.send_interval(self(), :repair)

    :ok = GenServer.cast(self(), :repair)

    {:ok,
     %State{
       limit: Keyword.get(opts, :limit, 5000),
       fuse_name: Keyword.get(opts, :fuse_name, fuse_name(tenant_id))
     }}
  end

  ## Repair

  @impl true
  def handle_cast(:repair, %State{limit: limit} = state) do
    from(d in Drive,
      join: sp in assoc(d, :start_position),
      join: ep in assoc(d, :end_position),
      select: [
        :id,
        :car_id,
        :start_date,
        {:start_position, [:id, :latitude, :longitude]},
        {:end_position, [:id, :latitude, :longitude]}
      ],
      where:
        (is_nil(d.start_address_id) or is_nil(d.end_address_id)) and
          (not is_nil(d.start_position_id) and not is_nil(d.end_position_id)),
      order_by: [desc: :id],
      preload: [start_position: sp, end_position: ep],
      limit: ^limit
    )
    |> Repo.all()
    |> repair(state)

    from(c in ChargingProcess,
      join: p in assoc(c, :position),
      select: [:id, :car_id, :start_date, {:position, [:id, :latitude, :longitude]}],
      where: is_nil(c.address_id) and not is_nil(c.position_id),
      order_by: [desc: :id],
      preload: [position: p],
      limit: ^limit
    )
    |> Repo.all()
    |> repair(state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:repair, state) do
    :ok = GenServer.cast(self(), :repair)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("Unexpected message: #{inspect(msg, pretty: true)}")
    {:noreply, state}
  end

  # Private

  defp repair([], %State{}), do: :ok

  defp repair([entity | rest], %State{fuse_name: fuse_name} = state) do
    case entity do
      %Drive{} = drive ->
        Logger.info("Repairing drive ##{drive.id} ...")

        drive
        |> Drive.changeset(%{
          start_address_id: get_address_id(drive.start_position, fuse_name),
          end_address_id: get_address_id(drive.end_position, fuse_name)
        })
        |> Repo.update()

      %ChargingProcess{} = charge ->
        Logger.info("Repairing charging process ##{charge.id} ...")

        charge
        |> ChargingProcess.changeset(%{address_id: get_address_id(charge.position, fuse_name)})
        |> Repo.update()
    end
    |> case do
      {:error, reason} -> Logger.warning("Failure: #{inspect(reason, pretty: true)}")
      {:ok, _entity} -> Logger.info("OK")
    end

    repair(rest, state)
  end

  defp get_address_id(nil, _fuse_name), do: nil

  defp get_address_id(%Position{} = position, fuse_name) do
    case :fuse.ask(fuse_name, :sync) do
      :ok ->
        Process.sleep(1500)

        case Locations.find_address(position) do
          {:error, {:geocoding_failed, reason}} ->
            Logger.warning("Geocoding failed: #{reason}")
            nil

          {:error, reason} ->
            :fuse.melt(fuse_name)
            Logger.warning("Address not found: #{inspect(reason)}")
            nil

          {:ok, %Address{display_name: _name, id: id}} ->
            id
        end

      :blown ->
        nil

      {:error, :not_found} ->
        Logger.debug("Installing circuit-breaker #{inspect(fuse_name)} ...")

        :fuse.install(
          fuse_name,
          {{:standard, 5, :timer.minutes(3)}, {:reset, :timer.minutes(15)}}
        )

        get_address_id(position, fuse_name)
    end
  end

  defp fuse_name(nil), do: :addr_fuse
  defp fuse_name(tenant_id), do: :"addr_fuse_#{:erlang.phash2(tenant_id)}"
end
