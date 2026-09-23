defmodule TeslaMate.Repo.Migrations.RecreateGeoExtensions do
  use Ecto.Migration

  def change do
    if prefix() in [nil, "public"] do
      execute("DROP EXTENSION cube CASCADE")
      execute("CREATE EXTENSION cube WITH SCHEMA public")
      execute("CREATE EXTENSION earthdistance WITH SCHEMA public")
    end
  end
end
