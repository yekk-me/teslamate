defmodule TeslaMate.MultiTenant.HTTPDirectory do
  @moduledoc """
  Loads tenant assignments from a control-plane HTTP endpoint.

  The endpoint must return the same JSON shape as `FileDirectory`:

      {"tenants": [%{...}]}

  TeslaMate sends the node id both as `node_id` query param and
  `x-teslamate-node-id` header so the control plane can shard assignments.
  """

  @behaviour TeslaMate.MultiTenant.Directory

  alias TeslaMate.MultiTenant.Directory

  @impl true
  def list_tenants(opts) do
    with {:ok, url} <- fetch_url(opts),
         {:ok, response} <- client(opts).get(url_with_node_id(url, opts), headers(opts), opts),
         {:ok, data} <- decode_response(response),
         tenants when is_list(tenants) <- Map.get(data, "tenants"),
         {:ok, tenants} <- Directory.parse_tenants(tenants) do
      {:ok, tenants}
    else
      nil -> {:error, :tenant_directory_missing_tenants}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_tenant_directory}
    end
  end

  defp fetch_url(opts) do
    case Keyword.get(opts, :url) do
      nil -> {:error, :tenant_directory_url_missing}
      "" -> {:error, :tenant_directory_url_missing}
      url when is_binary(url) -> {:ok, url}
    end
  end

  defp client(opts), do: Keyword.get(opts, :client, __MODULE__.Client)

  defp headers(opts) do
    [
      {"accept", "application/json"},
      {"user-agent", "TeslaMate/#{Application.spec(:teslamate, :vsn) || "dev"}"},
      {"x-teslamate-node-id", Keyword.get(opts, :node_id, TeslaMate.MultiTenant.node_id())}
    ]
    |> maybe_authorize(Keyword.get(opts, :token))
  end

  defp maybe_authorize(headers, token) when token in [nil, ""], do: headers
  defp maybe_authorize(headers, token), do: [{"authorization", "Bearer #{token}"} | headers]

  defp url_with_node_id(url, opts) do
    node_id = Keyword.get(opts, :node_id, TeslaMate.MultiTenant.node_id())

    url
    |> URI.parse()
    |> append_query(%{"node_id" => node_id})
    |> URI.to_string()
  end

  defp append_query(%URI{} = uri, params) do
    existing =
      case uri.query do
        nil -> %{}
        query -> URI.decode_query(query)
      end

    %{uri | query: URI.encode_query(Map.merge(existing, params))}
  end

  defp decode_response(%Finch.Response{status: status, body: body}) when status in 200..299 do
    Jason.decode(body)
  end

  defp decode_response(%Finch.Response{status: 401}), do: {:error, :tenant_directory_unauthorized}
  defp decode_response(%Finch.Response{status: 403}), do: {:error, :tenant_directory_forbidden}

  defp decode_response(%Finch.Response{status: status, body: body}) do
    {:error, {:tenant_directory_http_error, status, truncate(body)}}
  end

  defp truncate(body) when is_binary(body) and byte_size(body) > 256,
    do: binary_part(body, 0, 256)

  defp truncate(body), do: body

  defmodule Client do
    @moduledoc false

    def get(url, headers, opts) do
      receive_timeout = Keyword.get(opts, :timeout, 10_000)

      Finch.build(:get, url, headers)
      |> Finch.request(TeslaMate.HTTP, receive_timeout: receive_timeout)
    end
  end
end
