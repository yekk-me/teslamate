defmodule MultiTenantControlAuthorize do
  @moduledoc false

  @tenant_id System.get_env("SMOKE_TENANT_ID", "tenant-real-a")

  def run do
    Logger.configure(level: :warning)

    for app <- [:inets, :ssl, :jason] do
      {:ok, _apps} = Application.ensure_all_started(app)
    end

    response = authorize_with_retry()
    write_authorize_response!(response)
    update_tenant_directory!(response)
  end

  defp authorize_with_retry do
    url = System.fetch_env!("TESLAMATE_INTERNAL_AUTHORIZE_URL")
    token = System.fetch_env!("TESLAMATE_INTERNAL_API_TOKEN")
    body = authorization_body()

    1..max_attempts()
    |> Enum.reduce_while(nil, fn attempt, _acc ->
      case post_json(url, token, body) do
        {:ok, 200, response_body} ->
          {:ok, response} = Jason.decode(response_body)
          {:halt, response}

        {:ok, status, response_body} when status in [409, 503] ->
          if attempt == max_attempts() do
            Mix.raise(
              "Tenant authorization did not become ready: HTTP #{status} #{truncate(response_body)}"
            )
          else
            Process.sleep(2_000)
            {:cont, nil}
          end

        {:ok, status, response_body} ->
          Mix.raise("Tenant authorization failed: HTTP #{status} #{truncate(response_body)}")

        {:error, reason} ->
          if attempt == max_attempts() do
            Mix.raise("Tenant authorization endpoint is not reachable: #{inspect(reason)}")
          else
            Process.sleep(2_000)
            {:cont, nil}
          end
      end
    end)
  end

  defp authorization_body do
    %{
      access_token: System.fetch_env!("TESLA_ACCESS_TOKEN"),
      refresh_token: System.fetch_env!("TESLA_REFRESH_TOKEN")
    }
    |> Jason.encode!()
  end

  defp post_json(url, token, body) do
    headers = [
      {~c"authorization", ~c"Bearer #{token}"},
      {~c"content-type", ~c"application/json"},
      {~c"accept", ~c"application/json"}
    ]

    request = {String.to_charlist(url), headers, ~c"application/json", String.to_charlist(body)}

    case :httpc.request(:post, request, [timeout: 120_000], body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:ok, status, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_authorize_response!(response) do
    path = System.fetch_env!("TENANT_AUTHORIZE_RESPONSE_PATH")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(response, pretty: true))
  end

  defp update_tenant_directory!(%{"data" => %{"vehicles" => vehicles}} = response) do
    selected = select_vehicles(vehicles)
    path = System.fetch_env!("TENANT_DIRECTORY_PATH")

    directory =
      path
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["tenants", Access.at(0), "vehicles"], selected)

    File.write!(path, Jason.encode!(directory, pretty: true))

    suffixes =
      selected
      |> Enum.map(fn vehicle -> vehicle["vin"] || "" end)
      |> Enum.map(&String.slice(&1, -6, 6))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(",")

    Mix.shell().info(
      "Authorized #{@tenant_id}; vehicles=#{length(vehicles)} selected=#{length(selected)} vin_suffixes=#{suffixes}"
    )

    Mix.shell().info("Updated control-plane directory from authorization response")
    response
  end

  defp update_tenant_directory!(_response), do: Mix.raise("Invalid authorization response")

  defp select_vehicles(vehicles) do
    case System.get_env("TESLA_VIN") do
      nil ->
        vehicles

      vin ->
        case Enum.filter(vehicles, &(&1["vin"] == vin)) do
          [] -> Mix.raise("TESLA_VIN was not found in authorized vehicles")
          selected -> selected
        end
    end
  end

  defp max_attempts do
    System.get_env("TENANT_AUTHORIZE_MAX_ATTEMPTS", "45") |> String.to_integer()
  end

  defp truncate(body) when is_binary(body) and byte_size(body) > 256,
    do: binary_part(body, 0, 256)

  defp truncate(body), do: body
end

MultiTenantControlAuthorize.run()
