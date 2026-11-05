defmodule XebaWeb.HealthControllerTest do
  use XebaWeb.ConnCase, async: true

  test "liveness is public and does not create a login session", %{conn: conn} do
    conn = get(conn, ~p"/health/live")

    assert json_response(conn, 200) == %{"status" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "readiness is public and succeeds when the database responds", %{conn: conn} do
    conn = get(conn, ~p"/health/ready")

    assert json_response(conn, 200) == %{"status" => "ok"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "supports HEAD requests used by monitoring tools", %{conn: conn} do
    conn = head(conn, ~p"/health/ready")

    assert conn.status == 200
    assert conn.resp_body == ""
  end
end
