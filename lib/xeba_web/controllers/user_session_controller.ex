defmodule XebaWeb.UserSessionController do
  use XebaWeb, :controller

  alias XebaWeb.UserAuth

  def create(conn, params) do
    case XebaWeb.LoginRateLimiter.check(conn.remote_ip) do
      :ok ->
        authenticate(conn, params)

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_resp(:too_many_requests, "Too many login attempts. Please try again later.")
    end
  end

  defp authenticate(conn, %{"auth" => %{"username" => username, "password" => password}}) do
    if UserAuth.valid_credentials?(username, password) do
      UserAuth.log_in(conn)
    else
      reject_login(conn)
    end
  end

  defp authenticate(conn, _params), do: reject_login(conn)

  defp reject_login(conn) do
    conn
    |> put_flash(:error, "Invalid username or password.")
    |> redirect(to: ~p"/log-in")
  end

  def delete(conn, _params), do: UserAuth.log_out(conn)
end
