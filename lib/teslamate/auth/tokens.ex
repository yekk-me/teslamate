defmodule TeslaMate.Auth.Tokens do
  use Ecto.Schema

  import Ecto.Changeset

  alias TeslaMate.Vault.Encrypted

  @schema_prefix :private

  schema "tokens" do
    field :provider, :string, default: "fleet_cn"
    field :refresh, Encrypted.Binary, redact: true
    field :access, Encrypted.Binary, redact: true

    timestamps()
  end

  @doc false
  def changeset(tokens, attrs) do
    tokens
    |> cast(attrs, [:access, :refresh, :provider])
    |> validate_required([:access, :refresh, :provider])
  end
end

