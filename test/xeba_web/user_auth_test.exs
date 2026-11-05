defmodule XebaWeb.UserAuthTest do
  use XebaWeb.ConnCase, async: true

  alias XebaWeb.UserAuth

  test "require_authenticated_user redirects anonymous users", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> fetch_flash()
      |> UserAuth.fetch_current_scope([])
      |> UserAuth.require_authenticated_user([])

    assert conn.halted
    assert redirected_to(conn) == ~p"/log-in"
  end

  test "require_authenticated_user allows signed-in users", %{conn: conn} do
    conn =
      conn
      |> log_in_user()
      |> UserAuth.fetch_current_scope([])
      |> UserAuth.require_authenticated_user([])

    refute conn.halted
    assert conn.assigns.current_scope.user.username == "admin"
  end

  test "a copied session cannot be reused after logout", %{conn: conn} do
    conn = conn |> log_in_user() |> fetch_flash()
    token = get_session(conn, :xeba_authenticated)
    assert Xeba.Sessions.valid?(token)
    conn |> fetch_flash() |> UserAuth.log_out()

    rejected = conn |> UserAuth.fetch_current_scope([]) |> UserAuth.require_authenticated_user([])
    assert rejected.halted
    assert redirected_to(rejected) == ~p"/log-in"
  end

  test "the HTTP pipeline validates the session only once", %{conn: conn} do
    conn = log_in_user(conn)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:xeba, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner and String.contains?(metadata.query, ~s(FROM "sessions")),
            do: send(owner, :session_lookup)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    conn = conn |> UserAuth.fetch_current_scope([]) |> UserAuth.require_authenticated_user([])
    refute conn.halted
    assert_receive :session_lookup
    refute_received :session_lookup
  end

  test "require_authenticated_user can validate without a prior scope fetch", %{conn: conn} do
    conn = conn |> log_in_user() |> UserAuth.require_authenticated_user([])
    refute conn.halted
    assert conn.assigns.current_scope.user.username == "admin"
  end

  test "a changed session token invalidates the request's cached authentication", %{conn: conn} do
    conn = conn |> log_in_user() |> fetch_flash() |> UserAuth.fetch_current_scope([])

    conn =
      conn
      |> put_session(:xeba_authenticated, "invalid")
      |> UserAuth.require_authenticated_user([])

    assert conn.halted
    assert conn.assigns.current_scope == nil
    assert redirected_to(conn) == ~p"/log-in"
  end

  test "a new request revalidates a revoked token", %{conn: conn} do
    signed_in = conn |> log_in_user() |> UserAuth.fetch_current_scope([])
    token = get_session(signed_in, :xeba_authenticated)
    Xeba.Sessions.revoke(token)

    next_request =
      build_conn() |> init_test_session(%{xeba_authenticated: token}) |> fetch_flash()

    rejected = UserAuth.require_authenticated_user(next_request, [])
    assert rejected.halted
    assert redirected_to(rejected) == ~p"/log-in"
  end
end
