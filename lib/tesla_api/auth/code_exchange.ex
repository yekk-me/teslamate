defmodule TeslaApi.Auth.CodeExchange do
  import TeslaApi.Auth, only: [post: 2]

  alias TeslaApi.{Auth, Error}

  @web_client_id TeslaApi.Auth.web_client_id()

  def exchange_code(code, opts \\ []) when is_binary(code) do
    data =
      %{
        grant_type: "authorization_code",
        client_id: System.get_env("TESLA_AUTH_CLIENT_ID", @web_client_id),
        code: code,
        redirect_uri: Keyword.get(opts, :redirect_uri, Auth.redirect_uri())
      }
      |> maybe_put(:code_verifier, Keyword.get(opts, :code_verifier))

    case post("#{issuer_url(opts)}/token" <> System.get_env("TOKEN", ""), data) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok,
         %Auth{
           token: body["access_token"],
           type: body["token_type"],
           expires_in: body["expires_in"],
           refresh_token: body["refresh_token"],
           created_at: body["created_at"]
         }}

      error ->
        Error.into(error, :authorization_code)
    end
  end

  defp issuer_url(opts) do
    Keyword.get(opts, :issuer_url) ||
      System.get_env("TESLA_AUTH_HOST", "https://auth.tesla.com") <>
        System.get_env("TESLA_AUTH_PATH", "/oauth2/v3")
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
