defmodule TeslaMate.MultiTenant.TrafficLimiter do
  @moduledoc """
  Tenant-scoped fixed-window limiter for high-cost external traffic.

  The first consumers should be Tesla API calls and MQTT publishes. A nil limit
  means unlimited, while a limit of 0 denies the bucket.
  """

  use GenServer

  alias TeslaMate.MultiTenant.Tenant
  alias TeslaMate.MultiTenant.Tenant.Limits

  @window_ms :timer.minutes(1)

  def start_link(opts) do
    tenant = Keyword.fetch!(opts, :tenant)
    GenServer.start_link(__MODULE__, tenant, name: via(tenant.id))
  end

  def via(tenant_id),
    do: {:via, Registry, {TeslaMate.MultiTenant.Registry, {:traffic_limiter, tenant_id}}}

  def allow?(tenant_id, bucket, cost \\ 1) when is_binary(tenant_id) do
    case lookup(tenant_id) do
      {:ok, pid} -> GenServer.call(pid, {:allow, bucket, cost})
      :error -> false
    end
  end

  def remaining(tenant_id, bucket) when is_binary(tenant_id) do
    case lookup(tenant_id) do
      {:ok, pid} -> GenServer.call(pid, {:remaining, bucket})
      :error -> 0
    end
  end

  @impl true
  def init(%Tenant{} = tenant) do
    {:ok, %{tenant_id: tenant.id, limits: tenant.limits || %Limits{}, windows: %{}}}
  end

  @impl true
  def handle_call({:allow, bucket, cost}, _from, state) when is_integer(cost) and cost > 0 do
    now = now_ms()
    limit = Limits.limit(state.limits, bucket)
    window = current_window(state.windows, bucket, now)

    cond do
      is_nil(limit) ->
        {:reply, true, state}

      limit <= 0 ->
        {:reply, false, state}

      window.used + cost <= limit ->
        windows = Map.put(state.windows, bucket, %{window | used: window.used + cost})
        {:reply, true, %{state | windows: windows}}

      true ->
        {:reply, false, state}
    end
  end

  def handle_call({:remaining, bucket}, _from, state) do
    now = now_ms()
    limit = Limits.limit(state.limits, bucket)

    remaining =
      case limit do
        nil ->
          :unlimited

        limit ->
          window = current_window(state.windows, bucket, now)
          max(limit - window.used, 0)
      end

    {:reply, remaining, state}
  end

  def child_spec(opts) do
    tenant = Keyword.fetch!(opts, :tenant)

    %{
      id: {:traffic_limiter, tenant.id},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  defp current_window(windows, bucket, now) do
    case Map.get(windows, bucket) do
      %{started_at: started_at} = window when now - started_at < @window_ms ->
        window

      _ ->
        %{started_at: now, used: 0}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp lookup(tenant_id) do
    case Registry.lookup(TeslaMate.MultiTenant.Registry, {:traffic_limiter, tenant_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
