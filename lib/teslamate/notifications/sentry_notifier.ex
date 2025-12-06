defmodule TeslaMate.Notifications.SentryNotifier do
  @moduledoc """
  监听哨兵模式事件并发送通知。

  ## 事件类型
  - `:sentry_mode_enabled` - 哨兵模式开启
  - `:sentry_mode_disabled` - 哨兵模式关闭
  - `:sentry_event_triggered` - 哨兵事件触发（正在录制）

  ## 使用方法

  ### 方法1: 在 application.ex 的 children 列表中添加

      # 在 TeslaMate.Vehicles 之后添加
      {TeslaMate.Notifications.SentryNotifier, car_id: 1}

  ### 方法2: 使用回调函数

      TeslaMate.Notifications.SentryNotifier.start_link(
        car_id: 1,
        on_event: fn event, data ->
          case event do
            :sentry_event_triggered ->
              IO.puts("🚨 哨兵事件触发！")
              # 发送推送通知、调用外部 API 等
            _ ->
              :ok
          end
        end
      )

  ### 方法3: 配置 Webhook URL

      TeslaMate.Notifications.SentryNotifier.start_link(
        car_id: 1,
        webhook_url: "https://your-server.com/sentry-webhook"
      )

  ### 方法4: 订阅 PubSub 事件

      # 在你的模块中订阅
      Phoenix.PubSub.subscribe(TeslaMate.PubSub, "teslamate/sentry_events/1")

      # 然后处理消息
      def handle_info({:sentry_event_triggered, event_data}, state) do
        # 处理哨兵事件
        {:noreply, state}
      end
  """

  use GenServer
  require Logger

  alias TeslaMate.Vehicles.Vehicle.Summary

  defstruct [
    :car_id,
    :last_sentry_mode,
    :last_display_state,
    :on_event,
    :webhook_url
  ]

  # API

  @doc """
  启动哨兵通知器。

  ## Options
  - `:car_id` - 车辆ID（必需）
  - `:on_event` - 事件回调函数 `fn event_type, event_data -> :ok end`
  - `:webhook_url` - Webhook URL，事件发生时会 POST 到此 URL
  """
  def start_link(opts) do
    car_id = Keyword.fetch!(opts, :car_id)
    GenServer.start_link(__MODULE__, opts, name: :"#{__MODULE__}_#{car_id}")
  end

  def child_spec(opts) do
    car_id = Keyword.fetch!(opts, :car_id)

    %{
      id: {__MODULE__, car_id},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc """
  订阅特定车辆的哨兵事件。

  ## Example

      TeslaMate.Notifications.SentryNotifier.subscribe(1)
  """
  def subscribe(car_id) do
    Phoenix.PubSub.subscribe(TeslaMate.PubSub, "teslamate/sentry_events/#{car_id}")
  end

  # Callbacks

  @impl true
  def init(opts) do
    car_id = Keyword.fetch!(opts, :car_id)
    on_event = Keyword.get(opts, :on_event)
    webhook_url = Keyword.get(opts, :webhook_url)

    # 订阅车辆摘要更新
    :ok = TeslaMate.Vehicles.Vehicle.subscribe_to_summary(car_id)

    Logger.info("SentryNotifier started for car #{car_id}")

    {:ok,
     %__MODULE__{
       car_id: car_id,
       last_sentry_mode: nil,
       last_display_state: nil,
       on_event: on_event,
       webhook_url: webhook_url
     }}
  end

  @impl true
  def handle_info(%Summary{} = summary, state) do
    state = check_sentry_mode_change(summary, state)
    state = check_sentry_event_triggered(summary, state)

    {:noreply,
     %{
       state
       | last_sentry_mode: summary.sentry_mode,
         last_display_state: summary.center_display_state
     }}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private

  defp check_sentry_mode_change(%Summary{sentry_mode: sentry_mode} = summary, state) do
    case {state.last_sentry_mode, sentry_mode} do
      {nil, _} ->
        # 初始状态，不触发事件
        state

      {false, true} ->
        Logger.info("🛡️ Sentry Mode enabled for car #{state.car_id}")
        emit_event(:sentry_mode_enabled, summary, state)

      {true, false} ->
        Logger.info("Sentry Mode disabled for car #{state.car_id}")
        emit_event(:sentry_mode_disabled, summary, state)

      _ ->
        state
    end
  end

  defp check_sentry_event_triggered(%Summary{center_display_state: 7} = summary, state) do
    if state.last_display_state != 7 do
      Logger.warning(
        "🚨 Sentry event TRIGGERED for car #{state.car_id}! Recording in progress. " <>
          "Location: #{summary.latitude}, #{summary.longitude}"
      )

      emit_event(:sentry_event_triggered, summary, state)
    else
      state
    end
  end

  defp check_sentry_event_triggered(_summary, state), do: state

  defp emit_event(event_type, summary, state) do
    event_data = build_event_data(event_type, summary, state)

    # 调用回调函数
    if is_function(state.on_event, 2) do
      state.on_event.(event_type, event_data)
    end

    # 发送 Webhook（如果配置了）
    if state.webhook_url do
      send_webhook(state.webhook_url, event_data)
    end

    # 广播到 PubSub
    broadcast_event(event_type, event_data, state.car_id)

    state
  end

  defp build_event_data(event_type, summary, state) do
    %{
      event_type: event_type,
      car_id: state.car_id,
      timestamp: DateTime.utc_now(),
      display_name: summary.display_name,
      location: %{
        latitude: summary.latitude,
        longitude: summary.longitude,
        geofence: get_geofence_name(summary.geofence)
      },
      sentry_mode: summary.sentry_mode,
      center_display_state: summary.center_display_state,
      battery_level: summary.battery_level,
      state: summary.state
    }
  end

  defp get_geofence_name(%{name: name}), do: name
  defp get_geofence_name(_), do: nil

  defp broadcast_event(event_type, event_data, car_id) do
    topic = "teslamate/sentry_events/#{car_id}"
    Phoenix.PubSub.broadcast(TeslaMate.PubSub, topic, {event_type, event_data})
  end

  defp send_webhook(url, event_data) do
    Task.start(fn ->
      body = Jason.encode!(event_data)

      case TeslaMate.HTTP.post(url, body, [{"content-type", "application/json"}]) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.debug("Webhook sent successfully to #{url}")

        {:ok, %{status: status}} ->
          Logger.warning("Webhook returned status #{status}: #{url}")

        {:error, reason} ->
          Logger.error("Webhook failed: #{inspect(reason)}")
      end
    end)
  end

end
