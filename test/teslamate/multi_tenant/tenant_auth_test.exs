defmodule TeslaMate.MultiTenant.TenantAuthTest do
  use ExUnit.Case, async: true

  alias TeslaApi.Auth
  alias TeslaMate.MultiTenant.TenantAuth

  test "validates tokens, stores them in the tenant repo and returns vehicle assignments" do
    parent = self()

    repo_runner = fn tenant_id, fun ->
      send(parent, {:repo_context, tenant_id})
      fun.()
    end

    assert {:ok, result} =
             TenantAuth.authorize(
               "tenant-auth-a",
               %{"access_token" => "old-access", "refresh_token" => "old-refresh"},
               auth_api: __MODULE__.AuthAPI,
               vehicle_api: __MODULE__.VehicleAPI,
               auth_context: __MODULE__.AuthContext,
               repo_runner: repo_runner
             )

    assert %{tenant_id: "tenant-auth-a", vehicles: [vehicle]} = result
    assert vehicle.id == "1001"
    assert vehicle.eid == "1001"
    assert vehicle.vid == "2001"
    assert vehicle.vin == "VIN-A"

    assert_receive {:refresh, %Auth{token: "old-access", refresh_token: "old-refresh"}}
    assert_receive {:list, %Auth{token: "new-access", refresh_token: "new-refresh"}}
    assert_receive {:repo_context, "tenant-auth-a"}
    assert_receive {:save, %Auth{token: "new-access", refresh_token: "new-refresh"}}
  end

  test "exchanges authorization code when supplied by control plane" do
    repo_runner = fn _tenant_id, fun -> fun.() end

    assert {:ok, %{vehicles: [_vehicle]}} =
             TenantAuth.authorize(
               "tenant-auth-code",
               %{
                 "code" => "oauth-code",
                 "redirect_uri" => "https://control/callback",
                 "code_verifier" => "verifier",
                 "issuer_url" => "https://auth.tesla.cn/oauth2/v3"
               },
               auth_api: __MODULE__.AuthAPI,
               vehicle_api: __MODULE__.VehicleAPI,
               auth_context: __MODULE__.AuthContext,
               repo_runner: repo_runner
             )

    assert_receive {:exchange_code, "oauth-code",
                    [
                      redirect_uri: "https://control/callback",
                      code_verifier: "verifier",
                      issuer_url: "https://auth.tesla.cn/oauth2/v3"
                    ]}

    refute_received {:refresh, _auth}
    assert_receive {:save, %Auth{token: "code-access", refresh_token: "code-refresh"}}
  end

  test "returns clear error when tenant repo is not running" do
    repo_runner = fn tenant_id, _fun -> raise "tenant repo is not running for #{tenant_id}" end

    assert {:error, :tenant_repo_not_running} =
             TenantAuth.authorize(
               "tenant-missing-repo",
               %{"access_token" => "old-access", "refresh_token" => "old-refresh"},
               auth_api: __MODULE__.AuthAPI,
               vehicle_api: __MODULE__.VehicleAPI,
               auth_context: __MODULE__.AuthContext,
               repo_runner: repo_runner
             )

    refute_received {:refresh, _auth}
    refute_received {:list, _auth}
    refute_received {:save, _auth}
  end

  defmodule AuthAPI do
    def refresh(%Auth{} = auth) do
      send(self(), {:refresh, auth})
      {:ok, %Auth{token: "new-access", refresh_token: "new-refresh", expires_in: 3600}}
    end

    def exchange_code(code, opts) do
      send(self(), {:exchange_code, code, opts})
      {:ok, %Auth{token: "code-access", refresh_token: "code-refresh", expires_in: 3600}}
    end
  end

  defmodule VehicleAPI do
    def list(%Auth{} = auth) do
      send(self(), {:list, auth})

      {:ok,
       [
         %TeslaApi.Vehicle{
           id: 1001,
           vehicle_id: 2001,
           vin: "VIN-A",
           display_name: "Model Y",
           state: "online"
         }
       ]}
    end
  end

  defmodule AuthContext do
    def save(%Auth{} = auth) do
      send(self(), {:save, auth})
      :ok
    end
  end
end
