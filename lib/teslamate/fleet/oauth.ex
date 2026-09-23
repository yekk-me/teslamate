defmodule TeslaMate.Fleet.OAuth do
  @moduledoc "One-use authorization state, isolated in each tenant's private schema."
  import Ecto.Query
  alias TeslaMate.Repo
  alias TeslaMate.MultiTenant.TenantContext

  def begin(tenant_id) do
    state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    with {:ok, url} <- TeslaApi.Fleet.authorization_url(state) do
      TenantContext.run(tenant_id, fn ->
        now = DateTime.utc_now()

        Repo.delete_all(from(s in "fleet_oauth_states", where: s.expires_at < ^now),
          prefix: TeslaMate.MultiTenant.SharedDatabase.private_prefix()
        )

        Repo.insert_all(
          "fleet_oauth_states",
          [%{digest: digest(state), expires_at: DateTime.add(now, 600, :second)}],
          prefix: TeslaMate.MultiTenant.SharedDatabase.private_prefix()
        )
      end)

      {:ok, %{authorization_url: url, expires_in: 600}}
    end
  rescue
    _ in RuntimeError -> {:error, :tenant_repo_not_running}
  end

  def consume(tenant_id, state) when is_binary(state) and byte_size(state) in 32..128 do
    TenantContext.run(tenant_id, fn ->
      hash = digest(state)
      now = DateTime.utc_now()

      case Repo.delete_all(
             from(s in "fleet_oauth_states",
               where: s.digest == ^hash and s.expires_at > ^now
             ),
             prefix: TeslaMate.MultiTenant.SharedDatabase.private_prefix()
           ) do
        {1, _} -> :ok
        _ -> {:error, :invalid_oauth_state}
      end
    end)
  end

  def consume(_, _), do: {:error, :invalid_oauth_state}
  defp digest(state), do: :crypto.hash(:sha256, state)
end
