defmodule TeslaMateWeb.MultiTenantAuthControllerTest do
  use TeslaMateWeb.ConnCase, async: false

  setup do
    Process.put(:multi_tenant_auth_controller_test_pid, self())
    System.put_env("TESLAMATE_INTERNAL_API_TOKEN", "internal-secret")

    original =
      Application.get_env(:teslamate, TeslaMateWeb.MultiTenantAuthController, [])

    Application.put_env(:teslamate, TeslaMateWeb.MultiTenantAuthController,
      tenant_auth: __MODULE__.TenantAuth
    )

    on_exit(fn ->
      System.delete_env("TESLAMATE_INTERNAL_API_TOKEN")
      Application.put_env(:teslamate, TeslaMateWeb.MultiTenantAuthController, original)
    end)

    :ok
  end

  test "authorizes tenant through protected internal endpoint", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer internal-secret")
      |> post("/api/internal/tenants/tenant-web-a/authorize", %{
        "access_token" => "access",
        "refresh_token" => "refresh"
      })

    assert %{
             "data" => %{
               "tenant_id" => "tenant-web-a",
               "vehicles" => [%{"id" => "1001"}]
             }
           } = json_response(conn, 200)

    assert_receive {__MODULE__.TenantAuth, "tenant-web-a",
                    %{
                      "tenant_id" => "tenant-web-a",
                      "access_token" => "access",
                      "refresh_token" => "refresh"
                    }}
  end

  test "rejects missing internal bearer token", %{conn: conn} do
    conn =
      post(conn, "/api/internal/tenants/tenant-web-a/authorize", %{
        "access_token" => "access",
        "refresh_token" => "refresh"
      })

    assert %{"error" => "unauthorized"} = json_response(conn, 401)
  end

  defmodule TenantAuth do
    def authorize(tenant_id, params) do
      send(Process.get(:multi_tenant_auth_controller_test_pid), {__MODULE__, tenant_id, params})

      {:ok,
       %{
         tenant_id: tenant_id,
         vehicles: [
           %{
             id: "1001",
             eid: "1001",
             vid: "2001",
             vin: "VIN-A",
             display_name: "Model Y",
             state: "online",
             status: "active"
           }
         ]
       }}
    end
  end
end
