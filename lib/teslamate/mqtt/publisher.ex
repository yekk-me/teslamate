defmodule TeslaMate.Mqtt.Publisher do
  use GenServer

  require Logger

  @name __MODULE__
  @timeout :timer.seconds(10)

  defstruct client_id: nil,
            tenant_id: nil,
            refs: %{}

  alias __MODULE__, as: State

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  def publish(topic, msg \\ nil, opts \\ []) do
    GenServer.call(@name, {:publish, topic, msg, opts}, @timeout)
  end

  def publish(name, topic, msg, opts) do
    GenServer.call(name, {:publish, topic, msg, opts}, @timeout)
  end

  # Callbacks

  @impl true
  def init(opts) do
    {:ok,
     %State{client_id: Keyword.fetch!(opts, :client_id), tenant_id: Keyword.get(opts, :tenant_id)}}
  end

  @impl true
  def handle_call({:publish, topic, msg, opts}, from, %State{client_id: id, refs: refs} = state) do
    opts = Keyword.put_new(opts, :timeout, round(@timeout * 0.95))

    with :ok <- allow_publish(state.tenant_id) do
      case Keyword.get(opts, :qos, 0) do
        0 ->
          :ok = Tortoise311.publish(id, topic, msg, opts)
          {:reply, :ok, state}

        _ ->
          {:ok, ref} = Tortoise311.publish(id, topic, msg, opts)
          {:noreply, %State{state | refs: Map.put(refs, ref, from)}}
      end
    else
      {:error, :rate_limited} ->
        {:reply, {:error, :rate_limited}, state}
    end
  end

  @impl true
  def handle_info({{Tortoise311, id}, ref, result}, %State{client_id: id, refs: refs} = state) do
    {from, refs} = Map.pop(refs, ref)
    GenServer.reply(from, result)
    {:noreply, %State{state | refs: refs}}
  end

  defp allow_publish(nil), do: :ok

  defp allow_publish(tenant_id) do
    if TeslaMate.MultiTenant.TrafficLimiter.allow?(tenant_id, :mqtt_publish) do
      :ok
    else
      {:error, :rate_limited}
    end
  end
end
