defmodule TeslaMate.Fleet.OAuthTest do
  use TeslaMate.DataCase
  alias TeslaMate.Fleet.OAuth

  setup do
    config = %{
      "TESLA_FLEET_CLIENT_ID" => "client",
      "TESLA_FLEET_CLIENT_SECRET" => "secret",
      "TESLA_FLEET_REDIRECT_URI" => "https://portal.example.cn/callback"
    }

    original = Map.new(config, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(config)

    on_exit(fn ->
      Enum.each(original, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    :ok
  end

  test "state is random, one-use and expires" do
    assert {:ok, %{authorization_url: url}} = OAuth.begin(nil)
    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    assert byte_size(state) == 43
    assert :ok = OAuth.consume(nil, state)
    assert {:error, :invalid_oauth_state} = OAuth.consume(nil, state)

    {:ok, %{authorization_url: url2}} = OAuth.begin(nil)
    other = url2 |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    refute state == other

    Repo.update_all(
      from(s in "fleet_oauth_states"),
      [set: [expires_at: ~U[2000-01-01 00:00:00.000000Z]]], prefix: "private")

    assert {:error, :invalid_oauth_state} = OAuth.consume(nil, other)
  end
end
