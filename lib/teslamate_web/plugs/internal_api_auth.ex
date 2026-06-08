defmodule TeslaMateWeb.Plugs.InternalApiAuth do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = System.get_env("TESLAMATE_INTERNAL_API_TOKEN")
    supplied = bearer_token(conn)

    if valid_token?(expected, supplied) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(:unauthorized, Jason.encode!(%{error: "unauthorized"}))
      |> halt()
    end
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token -> token
      _ -> nil
    end
  end

  defp valid_token?(expected, supplied)
       when is_binary(expected) and is_binary(supplied) and expected != "" do
    byte_size(expected) == byte_size(supplied) and Plug.Crypto.secure_compare(expected, supplied)
  end

  defp valid_token?(_expected, _supplied), do: false
end
