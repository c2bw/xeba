defmodule XebaWeb.SessionExpiryTest do
  use XebaWeb.ConnCase
  import Phoenix.LiveViewTest

  test "an expired live session cannot submit another event", %{conn: conn} do
    {:ok, view, _} = live(log_in_user(conn), ~p"/")
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    Xeba.Repo.update_all(Xeba.Sessions.Session, set: [expires_at: past])

    render_change(view, "filter_conversations", %{"chat_filter" => %{"query" => "anything"}})
    assert_redirect(view, ~p"/log-in")
  end

  test "revoking a session broadcasts disconnect and denies further events", %{conn: conn} do
    conn = log_in_user(conn)
    token = get_session(conn, :xeba_authenticated)
    topic = Xeba.Sessions.socket_id(token)
    XebaWeb.Endpoint.subscribe(topic)
    {:ok, view, _} = live(conn, ~p"/")
    Xeba.Sessions.revoke(token)

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    refute Xeba.Sessions.valid?(token)
    render_change(view, "filter_conversations", %{"chat_filter" => %{"query" => "anything"}})
    assert_redirect(view, ~p"/log-in")
  end
end
