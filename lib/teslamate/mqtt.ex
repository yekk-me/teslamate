defmodule TeslaMate.Mqtt do
  use Supervisor

  require Logger

  alias __MODULE__.{Publisher, PubSub, Handler}

  # API

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def restart_pubsub(name \\ __MODULE__) do
    case GenServer.whereis(name) do
      nil ->
        :ok

      _pid ->
        Logger.info("Restarting MQTT PubSub ...")

        :ok = Supervisor.terminate_child(name, PubSub)

        case Supervisor.restart_child(name, PubSub) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(opts) do
    shared? = TeslaMate.MultiTenant.SharedDatabase.enabled?()
    client_id = if shared?, do: shared_client_id(), else: generate_client_id()
    if shared?, do: validate_shared_broker!(opts)
    publisher_name = Keyword.get(opts, :publisher_name, Publisher)
    pubsub_name = Keyword.get(opts, :pubsub_name, PubSub)
    tenant_id = Keyword.get(opts, :tenant_id)

    children = [
      if(not shared?,
        do: {Tortoise311.Connection, connection_config(opts) ++ [client_id: client_id]}
      ),
      {Publisher, client_id: client_id, name: publisher_name, tenant_id: tenant_id},
      {PubSub,
       namespace: opts[:namespace],
       name: pubsub_name,
       publisher: {Publisher, publisher_name},
       vehicles: Keyword.get(opts, :vehicles),
       car_ids: Keyword.get(opts, :car_ids)}
    ]

    Supervisor.init(Enum.reject(children, &is_nil/1), strategy: :one_for_one)
  end

  def shared_child_spec do
    opts = Application.fetch_env!(:teslamate, :mqtt)
    {Tortoise311.Connection, connection_config(opts) ++ [client_id: shared_client_id()]}
  end

  defp shared_client_id, do: "TESLAMATE_SHARED_" <> TeslaMate.MultiTenant.node_id()

  defp validate_shared_broker!(opts) do
    shared = Application.fetch_env!(:teslamate, :mqtt)

    for key <- [:host, :username, :password, :tls] do
      unless opts[key] == shared[key], do: raise("tenant MQTT broker differs from shared broker")
    end

    default = if opts[:tls], do: 8883, else: 1883

    unless (opts[:port] || default) == (shared[:port] || default),
      do: raise("tenant MQTT port differs from shared broker")
  end

  # Private

  alias Tortoise311.Transport

  defp connection_config(opts) do
    socket_opts =
      if opts[:ipv6],
        do: [:inet6],
        else: []

    server =
      if opts[:tls] do
        verify =
          if opts[:accept_invalid_certs],
            do: :verify_none,
            else: :verify_peer

        {Transport.SSL,
         host: opts[:host],
         port: opts[:port] || 8883,
         cacertfile: CAStore.file_path(),
         verify: verify,
         opts: socket_opts}
      else
        {Transport.Tcp, host: opts[:host], port: opts[:port] || 1883, opts: socket_opts}
      end

    [
      user_name: opts[:username],
      password: opts[:password],
      server: server,
      handler: {Handler, []},
      subscriptions: []
    ]
  end

  defp generate_client_id do
    "TESLAMATE_" <> (:rand.uniform() |> to_string() |> Base.encode16() |> String.slice(0..10))
  end
end
