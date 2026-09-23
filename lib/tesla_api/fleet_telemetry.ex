defmodule TeslaApi.FleetTelemetry do
  @moduledoc "Signed telemetry provisioning through a server-configured trusted proxy."
  alias TeslaApi.{Auth, Error, Fleet}

  def proxy_url do
    case System.get_env("TESLA_FLEET_COMMAND_PROXY") do
      url when is_binary(url) ->
        case URI.parse(url) do
          %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
          when is_binary(host) and path in [nil, "", "/"] ->
            {:ok, String.trim_trailing(url, "/")}

          _ ->
            {:error, %Error{reason: :invalid_command_proxy}}
        end

      _ ->
        {:error, %Error{reason: :command_proxy_not_configured}}
    end
  end

  def run(%Auth{} = auth, vin, :configure) do
    with {:ok, proxy} <- proxy_url(),
         {:ok, config} <- vehicle_config(),
         {:ok, result} when is_map(result) <-
           request(auth, :post, proxy <> "/api/1/vehicles/fleet_telemetry_config", %{
             "vins" => [vin],
             "config" => config
           }) do
      skipped = Map.get(result, "skipped_vehicles", %{})

      if not is_map(skipped) or
           Enum.any?(skipped, fn {_reason, vehicles} -> vehicles not in [[], nil] end),
        do: {:error, %Error{reason: :vehicle_configuration_skipped}},
        else: {:ok, result}
    else
      {:error, error} -> {:error, error}
      _ -> {:error, %Error{reason: :invalid_telemetry_response}}
    end
  end

  def run(%Auth{} = auth, vin, action) when action in [:status, :errors] do
    suffix = if action == :status, do: "fleet_telemetry_config", else: "fleet_telemetry_errors"

    request(
      auth,
      :get,
      Fleet.api_url() <>
        "/api/1/vehicles/" <> URI.encode(vin, &URI.char_unreserved?/1) <> "/" <> suffix,
      nil
    )
  end

  defp vehicle_config do
    with path when is_binary(path) <- System.get_env("TESLA_FLEET_VEHICLE_CONFIG_FILE"),
         {:ok, body} <- File.read(path),
         {:ok, %{"hostname" => host, "ca" => ca, "fields" => fields} = config} <-
           Jason.decode(body),
         true <- is_binary(host) and host != "" and not String.contains?(host, "REPLACE"),
         true <- is_binary(ca) and String.contains?(ca, "BEGIN CERTIFICATE"),
         true <- is_map(fields) and map_size(fields) > 0 do
      {:ok, config}
    else
      _ -> {:error, %Error{reason: :invalid_vehicle_config}}
    end
  end

  defp request(auth, method, url, body) do
    client =
      Tesla.client(
        [
          {Tesla.Middleware.Headers, [{"authorization", "Bearer " <> auth.token}]},
          Tesla.Middleware.JSON
        ],
        {Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 60_000}
      )

    case Tesla.request(client, method: method, url: url, body: body) do
      {:ok, %Tesla.Env{status: 200, body: %{"response" => result}}} when is_map(result) or is_list(result) ->
        {:ok, result}

      {:ok, %Tesla.Env{status: 401}} ->
        {:error, %Error{reason: :unauthorized}}

      {:ok, %Tesla.Env{status: status}} ->
        {:error,
         %Error{reason: :telemetry_request_failed, message: "Fleet telemetry HTTP #{status}"}}

      {:error, _} ->
        {:error, %Error{reason: :telemetry_request_failed}}

      _ ->
        {:error, %Error{reason: :invalid_telemetry_response}}
    end
  end
end
