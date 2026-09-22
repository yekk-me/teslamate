defmodule TeslaApi.FleetTest do
  use ExUnit.Case
  import Mock
  alias TeslaApi.{Fleet, Auth}

  setup do
    values = %{"TESLA_FLEET_CLIENT_ID" => "test-client", "TESLA_FLEET_CLIENT_SECRET" => "test-secret",
      "TESLA_FLEET_REDIRECT_URI" => "https://portal.example.cn/callback"}
    previous = Map.new(values, fn {k, _} -> {k, System.get_env(k)} end)
    System.put_env(values)
    on_exit(fn -> Enum.each(previous, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end) end)
    :ok
  end

  test "authorization uses China endpoints, scoped data access and state" do
    state = String.duplicate("s", 43)
    assert {:ok, url} = Fleet.authorization_url(state)
    uri = URI.parse(url)
    params = URI.decode_query(uri.query)
    assert uri.host == "auth.tesla.cn"
    assert params["state"] == state
    assert params["redirect_uri"] == "https://portal.example.cn/callback"
    assert params["scope"] =~ "vehicle_location"
    refute params["scope"] =~ "vehicle_cmds"
  end

  test "code exchange ignores caller-supplied issuer and callback and rotates tokens" do
    with_mock Tesla, [:passthrough], post: fn _client, url, params ->
      assert url == "https://auth.tesla.cn/oauth2/v3/token"
      assert params.client_secret == "test-secret"
      assert params.audience == Fleet.api_url()
      assert params.redirect_uri == "https://portal.example.cn/callback"
      {:ok, %Tesla.Env{status: 200, body: Jason.encode!(%{access_token: "new-access", refresh_token: "new-refresh", expires_in: 3600})}}
    end do
      assert {:ok, %Auth{provider: "fleet_cn", refresh_token: "new-refresh"}} =
        Fleet.exchange_code("code", issuer_url: "https://untrusted.example", redirect_uri: "https://untrusted.example")
    end
  end

  test "legacy tokens are never sent to Fleet OAuth" do
    assert {:error, :fleet_reauthorization_required} = Auth.refresh(%Auth{provider: "owner", refresh_token: "legacy"})
  end

  test "refresh sends client id and rotated refresh token, errors exclude secrets" do
    with_mock Tesla, [:passthrough], post: fn _, url, params ->
      assert url == "https://auth.tesla.cn/oauth2/v3/token"
      assert params == %{grant_type: "refresh_token", client_id: "test-client", refresh_token: "rotated"}
      {:ok, %Tesla.Env{status: 401, body: "sensitive response"}}
    end do
      assert {:error, error} = Fleet.refresh(%Auth{refresh_token: "rotated"})
      refute inspect(error) =~ "sensitive"
      refute inspect(error) =~ "rotated"
    end
  end
end
