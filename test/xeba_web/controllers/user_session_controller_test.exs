defmodule XebaWeb.UserSessionControllerTest do
  use XebaWeb.ConnCase, async: true

  describe "POST /log-in" do
    setup %{conn: conn} do
      id = System.unique_integer([:positive])
      {:ok, conn: %{conn | remote_ip: {127, 1, div(id, 256), rem(id, 256)}}}
    end

    test "throttles login attempts, including correct credentials", %{conn: conn} do
      for _ <- 1..5 do
        response =
          post(conn, ~p"/log-in", %{"auth" => %{"username" => "admin", "password" => "wrong"}})

        assert redirected_to(response) == ~p"/log-in"
      end

      response =
        post(conn, ~p"/log-in", %{"auth" => %{"username" => "admin", "password" => "xeba"}})

      assert response.status == 429
      assert [retry_after] = get_resp_header(response, "retry-after")
      assert String.to_integer(retry_after) in 1..60
      refute get_session(response, :xeba_authenticated)
    end

    test "rejects malformed login parameters", %{conn: conn} do
      conn = post(conn, ~p"/log-in", %{})
      refute get_session(conn, :xeba_authenticated)
      assert redirected_to(conn) == ~p"/log-in"
    end

    test "logs in with the configured single user", %{conn: conn} do
      conn =
        post(conn, ~p"/log-in", %{
          "auth" => %{"username" => "admin", "password" => "xeba"}
        })

      assert get_session(conn, :xeba_authenticated)
      assert redirected_to(conn) == ~p"/"

      assert conn
             |> get_resp_header("set-cookie")
             |> Enum.any?(&String.contains?(&1, "max-age=5184000"))
    end

    test "rejects invalid credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/log-in", %{
          "auth" => %{"username" => "admin", "password" => "wrong"}
        })

      refute get_session(conn, :xeba_authenticated)
      assert redirected_to(conn) == ~p"/log-in"
    end
  end

  describe "DELETE /log-out" do
    test "clears the login session", %{conn: conn} do
      conn =
        conn
        |> log_in_user()
        |> delete(~p"/log-out")

      refute get_session(conn, :xeba_authenticated)
      assert redirected_to(conn) == ~p"/log-in"
    end
  end
end
