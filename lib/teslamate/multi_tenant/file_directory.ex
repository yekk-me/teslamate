defmodule TeslaMate.MultiTenant.FileDirectory do
  @moduledoc """
  Loads tenant assignments from a JSON file.

  Expected shape:

      {
        "tenants": [
          {
            "id": "tenant-a",
            "user_id": "user-a",
            "database": {
              "host": "localhost",
              "port": 5432,
              "username": "teslamate_a",
              "password": "secret",
              "name": "teslamate_tenant_a"
            },
            "mqtt": {
              "host": "localhost",
              "namespace": "tenant-a"
            },
            "vehicles": [
              {"id": "1", "vin": "5YJ...", "display_name": "Model Y"}
            ]
          }
        ]
      }
  """

  @behaviour TeslaMate.MultiTenant.Directory

  @impl true
  def list_tenants(opts) do
    path = Keyword.get(opts, :path)

    cond do
      is_nil(path) or path == "" ->
        {:error, :tenant_directory_path_missing}

      not File.exists?(path) ->
        {:error, {:tenant_directory_not_found, path}}

      true ->
        with {:ok, body} <- File.read(path),
             {:ok, data} <- Jason.decode(body),
             tenants when is_list(tenants) <- Map.get(data, "tenants"),
             {:ok, tenants} <- TeslaMate.MultiTenant.Directory.parse_tenants(tenants) do
          {:ok, tenants}
        else
          nil -> {:error, :tenant_directory_missing_tenants}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_tenant_directory}
        end
    end
  end
end
