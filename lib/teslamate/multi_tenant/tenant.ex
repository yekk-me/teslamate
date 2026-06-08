defmodule TeslaMate.MultiTenant.Tenant do
  @moduledoc """
  Tenant assignment loaded from the tenant directory.

  A tenant is the isolation boundary for database credentials, Tesla API state,
  vehicle logger workers and MQTT namespace.
  """

  alias TeslaMate.MultiTenant.Tenant.{Database, Limits, Mqtt, Vehicle}

  @enforce_keys [:id, :database]
  defstruct [
    :id,
    :user_id,
    :status,
    :database,
    :mqtt,
    :limits,
    vehicles: [],
    entitlements: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, id} <- fetch_string(attrs, "id"),
         {:ok, database} <- Database.new(Map.get(attrs, "database", %{})),
         {:ok, vehicles} <- vehicles(Map.get(attrs, "vehicles", [])),
         {:ok, mqtt} <- Mqtt.new(Map.get(attrs, "mqtt", %{})),
         {:ok, limits} <- Limits.new(Map.get(attrs, "limits", %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         user_id: string_or_nil(Map.get(attrs, "user_id")),
         status: Map.get(attrs, "status", "active"),
         database: database,
         mqtt: mqtt,
         limits: limits,
         vehicles: vehicles,
         entitlements: Map.get(attrs, "entitlements", %{}),
         metadata: Map.get(attrs, "metadata", %{})
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_tenant}

  def active?(%__MODULE__{status: status}), do: status in [nil, "", "active"]

  def fingerprint(%__MODULE__{} = tenant) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(tenant))
    |> Base.encode16(case: :lower)
  end

  defp vehicles(items) when is_list(items) do
    items
    |> Enum.map(&Vehicle.new/1)
    |> collect()
  end

  defp vehicles(_items), do: {:error, :invalid_vehicles}

  defp collect(results) do
    result =
      Enum.reduce_while(results, {:ok, []}, fn
        {:ok, item}, {:ok, acc} -> {:cont, {:ok, [item | acc]}}
        {:error, reason}, _acc -> {:halt, {:error, reason}}
      end)

    case result do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp fetch_string(attrs, key) do
    case string_or_nil(Map.get(attrs, key)) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp string_or_nil(_value), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end

defmodule TeslaMate.MultiTenant.Tenant.Database do
  @moduledoc false

  @enforce_keys [:name]
  defstruct [
    :host,
    :port,
    :username,
    :password,
    :name,
    :pool_size,
    :ssl,
    :pooler,
    :prepare
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, host} <- fetch_string(attrs, "host", "database.host"),
         {:ok, username} <- fetch_string(attrs, "username", "database.username"),
         {:ok, password} <- fetch_string(attrs, "password", "database.password"),
         {:ok, name} <- fetch_string(attrs, "name", "database.name"),
         pooler =
           string_or_nil(Map.get(attrs, "pooler")) ||
             TeslaMate.MultiTenant.tenant_database_pooler(),
         {:ok, prepare} <- prepare_mode(Map.get(attrs, "prepare"), pooler) do
      {:ok,
       %__MODULE__{
         host: host,
         port: int_or_nil(Map.get(attrs, "port")) || 5432,
         username: username,
         password: password,
         name: name,
         pool_size:
           int_or_nil(Map.get(attrs, "pool_size")) ||
             TeslaMate.MultiTenant.tenant_repo_pool_size(),
         ssl: truthy?(Map.get(attrs, "ssl")),
         pooler: pooler,
         prepare: prepare
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_database}

  def repo_opts(%__MODULE__{} = db, repo_name) do
    [
      name: repo_name,
      hostname: db.host,
      port: db.port,
      username: db.username,
      password: db.password,
      database: db.name,
      pool_size: db.pool_size,
      ssl: db.ssl
    ]
    |> maybe_put(:prepare, db.prepare)
  end

  defp fetch_string(attrs, key, label) do
    case string_or_nil(Map.get(attrs, key)) do
      nil -> {:error, {:missing, label}}
      value -> {:ok, value}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp string_or_nil(_value), do: nil

  defp int_or_nil(value) when is_integer(value), do: value

  defp int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp int_or_nil(_value), do: nil

  defp truthy?(value) when value in [true, "true", "1", "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp prepare_mode(value, pooler) do
    case string_or_nil(value) do
      "unnamed" -> {:ok, :unnamed}
      "named" -> {:ok, :named}
      nil -> {:ok, if(pgbouncer?(pooler), do: :unnamed)}
      mode -> {:error, {:invalid, "database.prepare", mode}}
    end
  end

  defp pgbouncer?(pooler) when is_binary(pooler) do
    pooler in ["pgbouncer", "transaction", "transaction_pooling"]
  end

  defp pgbouncer?(_pooler), do: false

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end

defmodule TeslaMate.MultiTenant.Tenant.Mqtt do
  @moduledoc false

  defstruct [
    :host,
    :port,
    :username,
    :password,
    :namespace,
    tls: false,
    disabled: false
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    {:ok,
     %__MODULE__{
       host: string_or_nil(Map.get(attrs, "host")) || "localhost",
       port: int_or_nil(Map.get(attrs, "port")) || 1883,
       username: string_or_nil(Map.get(attrs, "username")),
       password: string_or_nil(Map.get(attrs, "password")),
       namespace: string_or_nil(Map.get(attrs, "namespace")),
       tls: truthy?(Map.get(attrs, "tls")),
       disabled: truthy?(Map.get(attrs, "disabled"))
     }}
  end

  def new(nil), do: {:ok, %__MODULE__{}}
  def new(_attrs), do: {:error, :invalid_mqtt}

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp string_or_nil(_value), do: nil

  defp int_or_nil(value) when is_integer(value), do: value

  defp int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp int_or_nil(_value), do: nil

  defp truthy?(value) when value in [true, "true", "1", "yes", "on"], do: true
  defp truthy?(_value), do: false
end

defmodule TeslaMate.MultiTenant.Tenant.Limits do
  @moduledoc false

  defstruct [
    :max_vehicles,
    :max_active_vehicles,
    :tesla_api_requests_per_minute,
    :mqtt_publishes_per_minute
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    {:ok,
     %__MODULE__{
       max_vehicles: int_or_nil(Map.get(attrs, "max_vehicles")),
       max_active_vehicles: int_or_nil(Map.get(attrs, "max_active_vehicles")),
       tesla_api_requests_per_minute: int_or_nil(Map.get(attrs, "tesla_api_requests_per_minute")),
       mqtt_publishes_per_minute: int_or_nil(Map.get(attrs, "mqtt_publishes_per_minute"))
     }}
  end

  def new(nil), do: {:ok, %__MODULE__{}}
  def new(_attrs), do: {:error, :invalid_limits}

  def limit(%__MODULE__{tesla_api_requests_per_minute: limit}, :tesla_api), do: limit
  def limit(%__MODULE__{mqtt_publishes_per_minute: limit}, :mqtt_publish), do: limit
  def limit(%__MODULE__{}, _bucket), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp int_or_nil(value) when is_integer(value), do: value

  defp int_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp int_or_nil(_value), do: nil
end

defmodule TeslaMate.MultiTenant.Tenant.Vehicle do
  @moduledoc false

  @enforce_keys [:id]
  defstruct [
    :id,
    :vin,
    :vid,
    :eid,
    :display_name,
    :status
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    case string_or_nil(Map.get(attrs, "id")) do
      nil ->
        {:error, {:missing, "vehicle.id"}}

      id ->
        {:ok,
         %__MODULE__{
           id: id,
           vin: string_or_nil(Map.get(attrs, "vin")),
           vid: string_or_nil(Map.get(attrs, "vid")),
           eid: string_or_nil(Map.get(attrs, "eid")),
           display_name: string_or_nil(Map.get(attrs, "display_name")),
           status: Map.get(attrs, "status", "active")
         }}
    end
  end

  def new(_attrs), do: {:error, :invalid_vehicle}

  def active?(%__MODULE__{status: status}), do: status in [nil, "", "active"]

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp string_or_nil(_value), do: nil
end
