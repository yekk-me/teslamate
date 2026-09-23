defmodule TeslaMate.MultiTenant.SharedDatabaseTest do
  use ExUnit.Case, async: false
  alias TeslaMate.Repo
  alias TeslaMate.MultiTenant.{Tenant, TenantContext, TenantState}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    unless Process.whereis(TeslaMate.MultiTenant.Registry),
      do: start_supervised!({Registry, keys: :unique, name: TeslaMate.MultiTenant.Registry})

    for name <- ["tenant_isolation_a", "tenant_isolation_b"] do
      Ecto.Adapters.SQL.query!(Repo, "CREATE ROLE #{name} NOLOGIN", [])
      Ecto.Adapters.SQL.query!(Repo, "CREATE SCHEMA #{name} AUTHORIZATION #{name}", [])

      Ecto.Adapters.SQL.query!(
        Repo,
        "CREATE TABLE #{name}.isolation (id integer PRIMARY KEY, value text)",
        []
      )

      Ecto.Adapters.SQL.query!(Repo, "ALTER TABLE #{name}.isolation OWNER TO #{name}", [])

      {:ok, tenant} =
        Tenant.new(%{
          id: name,
          database: %{
            host: "localhost",
            username: "test",
            password: "test",
            name: "test",
            schema: name
          }
        })

      start_supervised!({TenantState, tenant: tenant})
    end

    old_multi = System.get_env("TESLAMATE_MULTI_TENANT")
    old_shared = System.get_env("TESLAMATE_SHARED_DATABASE")
    System.put_env("TESLAMATE_MULTI_TENANT", "true")
    System.put_env("TESLAMATE_SHARED_DATABASE", "true")

    on_exit(fn ->
      for {key, value} <- [
            {"TESLAMATE_MULTI_TENANT", old_multi},
            {"TESLAMATE_SHARED_DATABASE", old_shared}
          ] do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "same IDs, raw SQL and rollback remain within the tenant role" do
    for name <- ["tenant_isolation_a", "tenant_isolation_b"] do
      TenantContext.run(name, fn -> Repo.insert_all("isolation", [%{id: 1, value: name}]) end)
    end

    for name <- ["tenant_isolation_a", "tenant_isolation_b"] do
      TenantContext.run(name, fn ->
        assert %{rows: [[1, ^name]]} = Repo.query!("SELECT id, value FROM isolation")

        assert {:error, :deliberate} =
                 Repo.transaction(fn ->
                   Repo.query!("UPDATE isolation SET value = 'wrong'")
                   Repo.rollback(:deliberate)
                 end)
      end)
    end

    assert_raise RuntimeError, ~r/requires tenant context/, fn -> Repo.query!("SELECT 1") end
  end

  test "cannot enter another tenant while retaining a leased transaction" do
    TenantContext.run("tenant_isolation_a", fn ->
      assert_raise RuntimeError, ~r/cannot switch tenants/, fn ->
        Repo.transaction(fn ->
          TenantContext.run("tenant_isolation_b", fn -> Repo.query!("SELECT 1") end)
        end)
      end
    end)
  end
end
