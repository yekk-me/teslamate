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
    client_id = generate_client_id()
    publisher_name = Keyword.get(opts, :publisher_name, Publisher)
    pubsub_name = Keyword.get(opts, :pubsub_name, PubSub)
    tenant_id = Keyword.get(opts, :tenant_id)

    children = [
      {Tortoise311.Connection, connection_config(opts) ++ [client_id: client_id]},
      {Publisher, client_id: client_id, name: publisher_name, tenant_id: tenant_id},
      {PubSub,
       namespace: opts[:namespace],
       name: pubsub_name,
       publisher: {Publisher, publisher_name},
       vehicles: Keyword.get(opts, :vehicles),
       car_ids: Keyword.get(opts, :car_ids)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
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
