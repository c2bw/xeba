defmodule Xeba.Sessions do
  import Ecto.Query
  alias Xeba.Repo
  alias Xeba.Sessions.Session

  @lifetime_seconds 60 * 24 * 60 * 60

  def create do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    session = %Session{
      token_hash: hash(token),
      credentials_version: credentials_version(),
      expires_at:
        DateTime.utc_now()
        |> DateTime.add(@lifetime_seconds, :second)
        |> DateTime.truncate(:second)
    }

    case Repo.insert(session) do
      {:ok, _session} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  def valid?(token) when is_binary(token) and byte_size(token) == 43 do
    case Repo.get_by(Session, token_hash: hash(token)) do
      %Session{} = session ->
        DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt and
          Plug.Crypto.secure_compare(session.credentials_version, credentials_version())

      nil ->
        false
    end
  end

  def valid?(_token), do: false

  def revoke(token) when is_binary(token) do
    Repo.delete_all(from session in Session, where: session.token_hash == ^hash(token))
    XebaWeb.Endpoint.broadcast(socket_id(token), "disconnect", %{})
    :ok
  end

  def revoke(_token), do: :ok

  def socket_id(token), do: "xeba_sessions:" <> Base.url_encode64(hash(token), padding: false)

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp credentials_version do
    credentials = Application.fetch_env!(:xeba, XebaWeb.UserAuth)

    data =
      :erlang.term_to_binary(
        {Keyword.fetch!(credentials, :username), Keyword.fetch!(credentials, :password)}
      )

    :crypto.mac(:hmac, :sha256, XebaWeb.Endpoint.config(:secret_key_base), data)
  end
end
