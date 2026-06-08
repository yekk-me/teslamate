defmodule TeslaMate.MultiTenant.HTTPDirectoryTest do
  use ExUnit.Case, async: true

  alias TeslaMate.MultiTenant.HTTPDirectory
  alias TeslaMate.MultiTenant.Tenant

  test "loads tenants from a control-plane endpoint" do
    Process.put(:http_directory_test_pid, self())

    body =
      Jason.encode!(%{
        tenants: [
          %{
            id: "tenant-http-a",
            database: %{
              host: "pgbouncer",
              port: 6432,
              username: "tm_a",
              password: "secret",
              name: "teslamate_tenant_a",
              pooler: "pgbouncer"
            },
            mqtt: %{namespace: "tenant-http-a"},
            vehicles: []
          }
        ]
      })

    Process.put(:http_directory_response, {:ok, %Finch.Response{status: 200, body: body}})

    assert {:ok, [%Tenant{} = tenant]} =
             HTTPDirectory.list_tenants(
               url: "https://control.internal/tenants?cluster=cn",
               token: "directory-token",
               node_id: "node-a",
               client: __MODULE__.Client
             )

    assert tenant.id == "tenant-http-a"
    assert tenant.database.prepare == :unnamed

    assert_receive {:http_directory_get, url, headers, _opts}
    assert url == "https://control.internal/tenants?cluster=cn&node_id=node-a"
    assert {"authorization", "Bearer directory-token"} in headers
    assert {"x-teslamate-node-id", "node-a"} in headers
  end

  test "returns clear errors for control-plane auth failures" do
    Process.put(:http_directory_test_pid, self())
    Process.put(:http_directory_response, {:ok, %Finch.Response{status: 401, body: ""}})

    assert {:error, :tenant_directory_unauthorized} =
             HTTPDirectory.list_tenants(
               url: "https://control.internal/tenants",
               client: __MODULE__.Client
             )
  end

  defmodule Client do
    def get(url, headers, opts) do
      send(Process.get(:http_directory_test_pid), {:http_directory_get, url, headers, opts})
      Process.get(:http_directory_response)
    end
  end
end
