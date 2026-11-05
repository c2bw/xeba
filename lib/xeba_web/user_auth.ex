defmodule XebaWeb.UserAuth do
  use XebaWeb, :verified_routes

  import Phoenix.Controller
  import Plug.Conn

  alias Xeba.Sessions

  @session_key :xeba_authenticated

  def fetch_current_scope(conn, _opts) do
    token = get_session(conn, @session_key)
    authenticated? = Sessions.valid?(token)

    conn
    |> put_private(:xeba_authentication, {token, authenticated?})
    |> assign(:current_scope, current_scope(authenticated?))
  end

  def require_authenticated_user(conn, _opts) do
    token = get_session(conn, @session_key)

    conn =
      case conn.private[:xeba_authentication] do
        {^token, _authenticated?} -> conn
        _ -> fetch_current_scope(conn, [])
      end

    if elem(conn.private.xeba_authentication, 1) do
      conn
    else
      conn
      |> put_flash(:error, "Please log in to continue.")
      |> put_session(:user_return_to, current_path(conn))
      |> redirect(to: ~p"/log-in")
      |> halt()
    end
  end

  def log_in(conn) do
    return_to = get_session(conn, :user_return_to) || ~p"/"

    Sessions.revoke(get_session(conn, @session_key))
    {:ok, token} = Sessions.create()

    conn
    |> renew_session()
    |> put_session(@session_key, token)
    |> put_session(:live_socket_id, Sessions.socket_id(token))
    |> put_flash(:info, "Welcome back.")
    |> redirect(to: return_to)
  end

  def log_out(conn) do
    Sessions.revoke(get_session(conn, @session_key))

    conn
    |> renew_session()
    |> put_flash(:info, "Logged out.")
    |> redirect(to: ~p"/log-in")
  end

  def valid_credentials?(username, password) when is_binary(username) and is_binary(password) do
    secure_equal?(username, configured_username()) and
      secure_equal?(password, configured_password())
  end

  def valid_credentials?(_username, _password), do: false

  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont,
     Phoenix.Component.assign(
       socket,
       :current_scope,
       current_scope(session_authenticated?(session))
     )}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    if session_authenticated?(session) do
      token = session[Atom.to_string(@session_key)]
      socket = Phoenix.Component.assign(socket, :current_scope, current_scope(true))

      socket =
        socket
        |> Phoenix.LiveView.attach_hook(:session_events, :handle_event, fn _event,
                                                                           _params,
                                                                           socket ->
          validate_live_session(socket, token)
        end)
        |> Phoenix.LiveView.attach_hook(:session_params, :handle_params, fn _params,
                                                                            _uri,
                                                                            socket ->
          validate_live_session(socket, token)
        end)
        |> Phoenix.LiveView.attach_hook(:session_info, :handle_info, fn _message, socket ->
          validate_live_session(socket, token)
        end)

      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Please log in to continue.")
        |> Phoenix.LiveView.redirect(to: ~p"/log-in")

      {:halt, socket}
    end
  end

  defp validate_live_session(socket, token) do
    if Sessions.valid?(token) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/log-in")}
    end
  end

  defp session_authenticated?(session),
    do: Sessions.valid?(Map.get(session, Atom.to_string(@session_key)))

  defp current_scope(true), do: %{user: %{username: configured_username()}}
  defp current_scope(_), do: nil

  defp configured_username,
    do: Application.fetch_env!(:xeba, __MODULE__) |> Keyword.fetch!(:username)

  defp configured_password,
    do: Application.fetch_env!(:xeba, __MODULE__) |> Keyword.fetch!(:password)

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
