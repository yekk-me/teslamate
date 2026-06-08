defmodule TeslaMate.MultiTenant.ApiTest do
  use ExUnit.Case, async: false

  alias TeslaMate.Api

  test "supports tenant-scoped registry names" do
    {:ok, _apps} = Application.ensure_all_started(:fuse)
    start_supervised!({Registry, keys: :unique, name: TeslaMate.MultiTenant.Registry})

    auth_name = :multi_tenant_api_auth
    vehicles_name = :multi_tenant_api_vehicles
    api_name = {:via, Registry, {TeslaMate.MultiTenant.Registry, {:api, "tenant-api"}}}

    start_supervised!({AuthMock, name: auth_name, tokens: nil, pid: self()})
    start_supervised!({VehiclesMock, name: vehicles_name, pid: self()})

    start_supervised!(
      {Api, name: api_name, auth: {AuthMock, auth_name}, vehicles: {VehiclesMock, vehicles_name}}
    )

    refute Api.signed_in?(api_name)
    assert {:error, :not_signed_in} = Api.list_vehicles(api_name)
    assert :ok = Api.sign_out(api_name)
  end
end
