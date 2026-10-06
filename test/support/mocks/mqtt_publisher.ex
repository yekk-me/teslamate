defmodule MqttPublisherMock do
  use GenServer

  defstruct [:pid, failing: MapSet.new()]
  alias __MODULE__, as: State

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def publish(name, topic, msg, opts), do: GenServer.call(name, {:publish, topic, msg, opts})

  # Make publishes to these topics fail as if the tenant was rate limited.
  def fail_topics(name, topics), do: GenServer.call(name, {:fail_topics, MapSet.new(topics)})

  # Callbacks

  @impl true
  def init(opts) do
    {:ok, %State{pid: Keyword.fetch!(opts, :pid)}}
  end

  @impl true
  def handle_call({:publish, topic, _msg, _opts} = action, _from, %State{pid: pid} = state) do
    send(pid, {MqttPublisherMock, action})
    reply = if MapSet.member?(state.failing, topic), do: {:error, :rate_limited}, else: :ok
    {:reply, reply, state}
  end

  def handle_call({:fail_topics, topics}, _from, %State{} = state) do
    {:reply, :ok, %State{state | failing: topics}}
  end
end
