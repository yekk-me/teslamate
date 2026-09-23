defmodule TeslaMate.Repo.Migrations.CreatePrivateSchema do
  use Ecto.Migration
  defp data_prefix, do: prefix() || "public"

  defp private_prefix,
    do: if(data_prefix() == "public", do: "private", else: data_prefix() <> "_private")

  def up do
    if data_prefix() == "public" do
      execute(~s(CREATE SCHEMA IF NOT EXISTS "#{private_prefix()}";))
    end

    execute(~s(ALTER TABLE "#{data_prefix()}".tokens SET SCHEMA "#{private_prefix()}";))
  end

  def down do
    execute(~s(ALTER TABLE "#{private_prefix()}".tokens SET SCHEMA "#{data_prefix()}";))
    execute(~s(DROP SCHEMA "#{private_prefix()}";))
  end
end
