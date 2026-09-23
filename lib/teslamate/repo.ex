defmodule TeslaMate.Repo do
  use Ecto.Repo,
    otp_app: :teslamate,
    adapter: Ecto.Adapters.Postgres

  alias TeslaMate.MultiTenant.SharedDatabase

  # The role is transaction-local, including raw SQL. PostgreSQL resets it on
  # commit/rollback before the shared connection can be used by another tenant.
  defoverridable transaction: 2
  def transaction(fun, opts) do
    if SharedDatabase.enabled?() and not SharedDatabase.scoped?() do
      unless is_function(fun, 0), do: raise("shared database transactions require a zero-arity function")
      super(fn -> SharedDatabase.enter(fun) end, opts)
    else
      SharedDatabase.scope(fn -> super(fun, opts) end)
    end
  end

  @impl true
  def default_options(_operation) do
    if SharedDatabase.enabled?(), do: [prefix: SharedDatabase.schema!()], else: []
  end

  for {name, arity} <- [
        all: 2, one: 2, one!: 2, get: 3, get!: 3, get_by: 3, get_by!: 3,
        exists?: 2, insert: 2, insert!: 2, update: 2, update!: 2,
        delete: 2, delete!: 2, insert_or_update: 2, insert_or_update!: 2,
        insert_all: 3, update_all: 3, delete_all: 2, preload: 3,
        aggregate: 3, aggregate: 4, query: 3, query!: 3, checkout: 2
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)
    defoverridable [{name, arity}]
    def unquote(name)(unquote_splicing(args)) do
      SharedDatabase.scope(fn -> super(unquote_splicing(args)) end)
    end
  end
end
