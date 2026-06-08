defmodule TeslaMate.MultiTenant.ControlLoop do
  @moduledoc """
  Periodically syncs tenant assignments into the runtime supervisor.
  """

  use GenServer

  require Logger

  alias TeslaMate.MultiTenant.Directory
  alias TeslaMate.MultiTenant.RuntimeSupervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def sync(pid \\ __MODULE__), do: GenServer.call(pid, :sync)

  @impl true
  def init(opts) do
    state = %{
      directory: Keyword.get(opts, :directory, TeslaMate.MultiTenant.directory_module()),
      directory_opts: Keyword.get(opts, :directory_opts, TeslaMate.MultiTenant.directory_opts()),
      runtime_supervisor: Keyword.get(opts, :runtime_supervisor, RuntimeSupervisor),
      interval: Keyword.get(opts, :interval, TeslaMate.MultiTenant.sync_interval()),
      failures: 0,
      max_failures: Keyword.get(opts, :max_failures, TeslaMate.MultiTenant.max_sync_failures())
    }

    send(self(), :sync)
    {:ok, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {reply, state} = do_sync(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:sync, state) do
    {_reply, state} = do_sync(state)
    Process.send_after(self(), :sync, state.interval)
    {:noreply, state}
  end

  defp do_sync(state) do
    case Directory.load(state.directory, state.directory_opts) do
      {:ok, tenants} ->
        result = RuntimeSupervisor.sync(state.runtime_supervisor, tenants)
        {result, %{state | failures: 0}}

      {:error, reason} ->
        Logger.warning("Tenant directory sync failed: #{inspect(reason)}")
        state = %{state | failures: state.failures + 1}

        if state.failures >= state.max_failures do
          Logger.error(
            "Tenant directory sync failed #{state.failures} times; stopping tenant runtimes"
          )

          :ok = RuntimeSupervisor.sync(state.runtime_supervisor, [])
        end

        {{:error, reason}, state}
    end
  end
end
