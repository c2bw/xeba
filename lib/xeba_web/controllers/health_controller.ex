defmodule XebaWeb.HealthController do
  use XebaWeb, :controller

  def live(conn, _params), do: respond(conn, :ok, "ok")

  def ready(conn, _params) do
    if database_ready?() do
      respond(conn, :ok, "ok")
    else
      respond(conn, :service_unavailable, "unavailable")
    end
  end

  defp database_ready? do
    case Ecto.Adapters.SQL.query(Xeba.Repo, "SELECT 1", [],
           timeout: 1_000,
           queue: false,
           log: false
         ) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp respond(conn, status, message) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(%{status: message})
  end
end
