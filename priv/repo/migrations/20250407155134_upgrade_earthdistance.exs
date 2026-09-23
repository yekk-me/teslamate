defmodule TeslaMate.Repo.Migrations.UpgradeEarthdistance do
  use Ecto.Migration

  def change do
    if prefix() in [nil, "public"] do
      execute("ALTER EXTENSION earthdistance UPDATE")
    end
  end
end
