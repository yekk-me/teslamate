defmodule TeslaMate.MultiTenant do
  @moduledoc """
  Runtime switch and helpers for the multi-tenant TeslaMate runtime.

  The feature is disabled by default. When enabled, TeslaMate starts a tenant
  directory sync loop instead of the single-tenant Repo/API/Vehicles tree.
  """

  @truthy ~w(1 true TRUE yes YES on ON)

  def enabled? do
    env_truthy?("TESLAMATE_MULTI_TENANT") ||
      app_config()
      |> Keyword.get(:enabled, false)
      |> truthy?()
  end

  def node_id do
    System.get_env("TESLAMATE_NODE_ID") ||
      Keyword.get(app_config(), :node_id) ||
      System.get_env("HOSTNAME") ||
      "local"
  end

  def directory_module do
    case Keyword.get(app_config(), :directory) do
      nil ->
        if System.get_env("TESLAMATE_TENANT_DIRECTORY_URL") in [nil, ""] do
          TeslaMate.MultiTenant.FileDirectory
        else
          TeslaMate.MultiTenant.HTTPDirectory
        end

      module ->
        module
    end
  end

  def directory_opts do
    app_config()
    |> Keyword.get(:directory_opts, [])
    |> Keyword.put_new(:path, System.get_env("TESLAMATE_TENANT_DIRECTORY"))
    |> Keyword.put_new(:url, System.get_env("TESLAMATE_TENANT_DIRECTORY_URL"))
    |> Keyword.put_new(:token, System.get_env("TESLAMATE_TENANT_DIRECTORY_TOKEN"))
    |> Keyword.put_new(:node_id, node_id())
    |> Keyword.put_new(
      :timeout,
      System.get_env("TESLAMATE_TENANT_DIRECTORY_TIMEOUT_MS", "10000") |> String.to_integer()
    )
  end

  def sync_interval do
    case System.get_env("TESLAMATE_TENANT_SYNC_INTERVAL_MS") do
      nil -> Keyword.get(app_config(), :sync_interval, :timer.seconds(15))
      value -> String.to_integer(value)
    end
  end

  def start_repo? do
    case System.get_env("TESLAMATE_TENANT_START_REPO") do
      nil -> Keyword.get(app_config(), :start_repo?, true)
      value -> truthy?(value)
    end
  end

  def start_vehicle_workers? do
    case System.get_env("TESLAMATE_TENANT_START_VEHICLE_WORKERS") do
      nil -> Keyword.get(app_config(), :start_vehicle_workers?, true)
      value -> truthy?(value)
    end
  end

  def start_mqtt? do
    case System.get_env("TESLAMATE_TENANT_START_MQTT") do
      nil -> Keyword.get(app_config(), :start_mqtt?, true)
      value -> truthy?(value)
    end
  end

  def start_repair? do
    case System.get_env("TESLAMATE_TENANT_START_REPAIR") do
      nil -> Keyword.get(app_config(), :start_repair?, true)
      value -> truthy?(value)
    end
  end

  def start_terrain? do
    case System.get_env("TESLAMATE_TENANT_START_TERRAIN") do
      nil -> Keyword.get(app_config(), :start_terrain?, true)
      value -> truthy?(value)
    end
  end

  def start_web? do
    case System.get_env("TESLAMATE_TENANT_START_WEB") do
      nil -> Keyword.get(app_config(), :start_web?, false)
      value -> truthy?(value)
    end
  end

  def vehicle_runtime do
    case System.get_env("TESLAMATE_TENANT_VEHICLE_RUNTIME") do
      nil -> Keyword.get(app_config(), :vehicle_runtime, :logger)
      "placeholder" -> :placeholder
      "logger" -> :logger
      value when is_binary(value) -> String.to_existing_atom(value)
    end
  rescue
    _ in ArgumentError -> :logger
  end

  def max_sync_failures do
    case System.get_env("TESLAMATE_TENANT_MAX_SYNC_FAILURES") do
      nil -> Keyword.get(app_config(), :max_sync_failures, 3)
      value -> String.to_integer(value)
    end
  end

  def tenant_repo_pool_size do
    case System.get_env("TESLAMATE_TENANT_REPO_POOL_SIZE") do
      nil -> Keyword.get(app_config(), :tenant_repo_pool_size, 1)
      value -> String.to_integer(value)
    end
  end

  def tenant_repair_limit do
    case System.get_env("TESLAMATE_TENANT_REPAIR_LIMIT") do
      nil -> Keyword.get(app_config(), :tenant_repair_limit, 250)
      value -> String.to_integer(value)
    end
  end

  def tenant_database_pooler do
    System.get_env("TESLAMATE_TENANT_DB_POOLER") ||
      Keyword.get(app_config(), :tenant_database_pooler)
  end

  defp app_config, do: Application.get_env(:teslamate, __MODULE__, [])

  defp env_truthy?(name), do: System.get_env(name) |> truthy?()

  defp truthy?(value) when value in [true, "true"], do: true
  defp truthy?(value) when is_binary(value), do: value in @truthy
  defp truthy?(_value), do: false
end
