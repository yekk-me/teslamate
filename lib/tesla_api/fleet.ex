defmodule TeslaApi.Fleet do
  @moduledoc "China Fleet API configuration. Credentials are resolved at runtime, never from callbacks."

  @api "https://fleet-api.prd.cn.vn.cloud.tesla.cn"
  @auth "https://auth.tesla.cn/oauth2/v3"
  @scopes "openid offline_access vehicle_device_data vehicle_location"

  def enabled?, do: true
  def api_url, do: @api
  def auth_url, do: @auth
  def client_id, do: System.get_env("TESLA_FLEET_CLIENT_ID")
  def redirect_uri, do: System.get_env("TESLA_FLEET_REDIRECT_URI")
  def scopes, do: @scopes

  def configured? do
    Enum.all?([client_id(), secret(), redirect_uri()], &(is_binary(&1) and &1 != "")) and
      match?(%URI{scheme: "https", host: host} when is_binary(host), URI.parse(redirect_uri()))
  end

  def authorization_url(state) when is_binary(state) and byte_size(state) >= 32 do
    if configured?() do
      {:ok, @auth <> "/authorize?" <> URI.encode_query(%{
        client_id: client_id(), redirect_uri: redirect_uri(), response_type: "code",
        scope: @scopes, state: state, prompt_missing_scopes: true,
        require_requested_scopes: true
      })}
    else
      {:error, :fleet_not_configured}
    end
  end

  def exchange_code(code, _opts \\ []) do
    token(%{grant_type: "authorization_code", client_id: client_id(),
      client_secret: secret(), code: code, audience: @api, redirect_uri: redirect_uri()})
  end

  def refresh(%TeslaApi.Auth{refresh_token: refresh}) do
    token(%{grant_type: "refresh_token", client_id: client_id(), refresh_token: refresh})
  end

  defp token(params) do
    if configured?() do
      client = Tesla.client([{Tesla.Middleware.FormUrlencoded, []}], {Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 30_000})

      case Tesla.post(client, @auth <> "/token", params) do
        {:ok, %Tesla.Env{status: 200, body: body}} -> decode_token(body)
        {:ok, %Tesla.Env{status: status}} ->
          {:error, %TeslaApi.Error{reason: :fleet_authorization, message: "Fleet OAuth HTTP #{status}"}}
        {:error, _} -> {:error, %TeslaApi.Error{reason: :fleet_authorization}}
      end
    else
      {:error, :fleet_not_configured}
    end
  end

  defp decode_token(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> decode_token(data)
      _ -> {:error, :invalid_fleet_token_response}
    end
  end

  defp decode_token(%{"access_token" => at, "refresh_token" => rt, "expires_in" => seconds})
       when is_binary(at) and byte_size(at) > 0 and is_binary(rt) and byte_size(rt) > 0 and
              is_integer(seconds) and seconds > 0 do
    {:ok, %TeslaApi.Auth{token: at, refresh_token: rt, expires_in: seconds,
      created_at: System.system_time(:second), type: "Bearer", provider: "fleet_cn"}}
  end

  defp decode_token(_), do: {:error, :invalid_fleet_token_response}
  defp secret, do: System.get_env("TESLA_FLEET_CLIENT_SECRET")
end
