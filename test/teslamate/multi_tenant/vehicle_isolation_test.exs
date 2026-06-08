defmodule TeslaMate.MultiTenant.VehicleIsolationTest do
  use ExUnit.Case, async: false

  alias TeslaMate.Vehicles.Vehicle

  setup do
    if Process.whereis(TeslaMate.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: TeslaMate.PubSub})
    end

    :ok
  end

  test "tenant scoped summary subscriptions do not receive another tenant's car id" do
    :ok = Vehicle.subscribe_to_summary("tenant-a", 1)

    :ok =
      Phoenix.PubSub.broadcast(
        TeslaMate.PubSub,
        "#{Vehicle}/summary/tenant-b/1",
        {:summary, :tenant_b}
      )

    refute_receive {:summary, :tenant_b}, 30

    :ok =
      Phoenix.PubSub.broadcast(
        TeslaMate.PubSub,
        "#{Vehicle}/summary/tenant-a/1",
        {:summary, :tenant_a}
      )

    assert_receive {:summary, :tenant_a}
  end

  test "single tenant summary subscription keeps the original topic shape" do
    :ok = Vehicle.subscribe_to_summary(1)
    :ok = Phoenix.PubSub.broadcast(TeslaMate.PubSub, "#{Vehicle}/summary/1", :single_tenant)

    assert_receive :single_tenant
  end
end
