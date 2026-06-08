defmodule MultiTenantControlServer do
  @moduledoc false

  import Plug.Conn

  def start do
    Logger.configure(level: :warning)

    for app <- [:logger, :crypto, :ranch, :cowboy, :cowboy_telemetry, :plug, :plug_cowboy, :jason] do
      {:ok, _apps} = Application.ensure_all_started(app)
    end

    {:ok, _pid} = Plug.Cowboy.http(__MODULE__, [], ip: {0, 0, 0, 0}, port: 8080)
    Process.sleep(:infinity)
  end

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: ["tenants"]} = conn, _opts) do
    expected = System.fetch_env!("CONTROL_TOKEN")

    case get_req_header(conn, "authorization") do
      ["Bearer " <> supplied] when supplied == expected ->
        body = System.fetch_env!("DIRECTORY_PATH") |> File.read!()
        Jason.decode!(body)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      _ ->
        send_resp(conn, 401, "")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")
end

MultiTenantControlServer.start()
