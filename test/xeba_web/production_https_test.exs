defmodule XebaWeb.ProductionHttpsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  setup do
    config = Config.Reader.read!("config/prod.exs")
    options = config[:xeba][XebaWeb.Endpoint][:force_ssl]
    ssl = Plug.SSL.init(Keyword.put(options, :host, "xeba.example.com"))
    {:ok, ssl: ssl}
  end

  test "redirects HTTP to the configured public hostname, preserving path and query", %{ssl: ssl} do
    conn = conn(:get, "http://untrusted.example/log-in?next=%2F") |> Plug.SSL.call(ssl)

    assert conn.status == 301
    assert conn.halted
    assert get_resp_header(conn, "location") == ["https://xeba.example.com/log-in?next=%2F"]
  end

  test "redirects form submissions without changing their method", %{ssl: ssl} do
    conn = conn(:post, "http://localhost/log-in") |> Plug.SSL.call(ssl)

    assert conn.status == 307
    assert conn.halted
  end

  test "recognizes the protocol supplied by the TLS proxy and sets HSTS", %{ssl: ssl} do
    conn =
      conn(:get, "/log-in")
      |> put_req_header("x-forwarded-proto", "https")
      |> Plug.SSL.call(ssl)

    assert conn.scheme == :https
    refute conn.halted
    assert get_resp_header(conn, "strict-transport-security") == ["max-age=31536000"]
  end

  test "allows only the health endpoints over HTTP for container probes", %{ssl: ssl} do
    for path <- ["/health/live", "/health/ready"] do
      conn = conn(:get, path) |> Plug.SSL.call(ssl)
      refute conn.halted
    end

    conn = conn(:get, "/health/other") |> Plug.SSL.call(ssl)
    assert conn.status == 301
  end
end
