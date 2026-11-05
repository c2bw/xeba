defmodule XebaWeb.RouterTest do
  use XebaWeb.ConnCase

  test "GET / redirects anonymous users to log in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/log-in"
  end
end
