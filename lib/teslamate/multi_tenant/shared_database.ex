defmodule TeslaMate.MultiTenant.SharedDatabase do
  @moduledoc "Single physical Repo pool with transaction-local tenant roles and schemas."
  alias TeslaMate.MultiTenant.{TenantContext, TenantState}
  @scope_key {__MODULE__, :scope}

  defmacro __before_compile__(_env) do
    definitions =
      for name <- [:query, :query!, :query_many, :query_many!] do
        quote do
          defoverridable [{unquote(name), 3}]

          def unquote(name)(sql, params, opts) do
            TeslaMate.MultiTenant.SharedDatabase.scope(fn -> super(sql, params, opts) end)
          end
        end
      end

    {:__block__, [], definitions}
  end

  def enabled?,
    do: TeslaMate.MultiTenant.enabled?() and System.get_env("TESLAMATE_SHARED_DATABASE") == "true"

  def valid_schema?(schema),
    do: is_binary(schema) and Regex.match?(~r/^tenant_[a-z0-9_]{1,48}$/, schema)

  def schema! do
    tenant_id = TenantContext.tenant_id() || raise "database access requires tenant context"
    schema = TenantState.tenant(tenant_id).database.schema
    if valid_schema?(schema), do: schema, else: raise("invalid tenant database schema")
  end

  def private_prefix do
    if enabled?(), do: schema!() <> "_private", else: "private"
  end

  def scoped?, do: Process.get(@scope_key) != nil

  def scope(fun) do
    if enabled?() and not scoped?() do
      case TeslaMate.Repo.transaction(fun) do
        {:ok, value} -> value
        {:error, reason} -> raise "tenant database transaction failed: #{inspect(reason)}"
      end
    else
      if enabled?() and Process.get(@scope_key) != schema!(),
        do: raise("cannot switch tenants inside a transaction")

      fun.()
    end
  end

  def enter(fun) do
    schema = schema!()
    previous = Process.put(@scope_key, schema)

    try do
      Ecto.Adapters.SQL.query!(TeslaMate.Repo, "SET LOCAL ROLE \"#{schema}\"", [])

      Ecto.Adapters.SQL.query!(
        TeslaMate.Repo,
        "SET LOCAL search_path TO \"#{schema}\", public",
        []
      )

      fun.()
    after
      if previous, do: Process.put(@scope_key, previous), else: Process.delete(@scope_key)
    end
  end

  # Run in a separate maintenance process with TESLAMATE_MULTI_TENANT=false.
  # Provisioning creates the role and schemas before calling this function.
  def migrate(schema) do
    unless valid_schema?(schema), do: raise("invalid tenant schema")

    if TeslaMate.MultiTenant.enabled?(),
      do: raise("migrations require an isolated maintenance process")

    if Process.whereis(TeslaMate.Repo), do: raise("migration Repo must not already be running")
    Application.load(:teslamate)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:cloak_ecto)
    {:ok, vault} = TeslaMate.Vault.start_link([])
    opts = Application.fetch_env!(:teslamate, TeslaMate.Repo)

    after_connect = fn conn ->
      Postgrex.query!(conn, "SET ROLE \"#{schema}\"", [])
      Postgrex.query!(conn, "SET search_path TO \"#{schema}\", public", [])
    end

    {:ok, repo} =
      TeslaMate.Repo.start_link(
        Keyword.merge(opts,
          pool_size: 2,
          pool: DBConnection.ConnectionPool,
          after_connect: after_connect
        )
      )

    try do
      Ecto.Migrator.run(TeslaMate.Repo, :up, all: true, prefix: schema)
    after
      Supervisor.stop(repo)
      GenServer.stop(vault)
    end
  end
end
