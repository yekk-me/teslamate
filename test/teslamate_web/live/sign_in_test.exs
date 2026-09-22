defmodule TeslaMateWeb.SignInLiveTest do
  use TeslaMateWeb.ConnCase

  test "directs users to official authorization without accepting Owner tokens", %{conn: conn} do
    assert {:ok, _view, html} = live(conn, "/sign_in")
    assert html =~ "Tesla Fleet API"
    refute html =~ "tokens[access]"
    refute html =~ "tokens[refresh]"
    refute html =~ "tm-login"
  end
end
