defmodule Xeba.SessionsTest do
  use Xeba.DataCase
  alias Xeba.Sessions
  alias Xeba.Sessions.Session

  test "opaque tokens can be revoked and are stored only as hashes" do
    {:ok, token} = Sessions.create()
    assert Sessions.valid?(token)
    session = Repo.one!(Session)
    refute session.token_hash == token
    assert :ok = Sessions.revoke(token)
    refute Sessions.valid?(token)
    refute Sessions.valid?(true)
    refute Sessions.valid?(String.duplicate("x", 100_000))
  end

  test "expiry is checked by the server" do
    {:ok, token} = Sessions.create()
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
    Repo.update_all(Session, set: [expires_at: past])
    refute Sessions.valid?(token)
  end

  test "rotating either configured credential invalidates existing sessions" do
    previous = Application.fetch_env!(:xeba, XebaWeb.UserAuth)
    on_exit(fn -> Application.put_env(:xeba, XebaWeb.UserAuth, previous) end)

    for field <- [:username, :password] do
      Application.put_env(:xeba, XebaWeb.UserAuth, previous)
      {:ok, token} = Sessions.create()
      Application.put_env(:xeba, XebaWeb.UserAuth, Keyword.put(previous, field, "rotated"))
      refute Sessions.valid?(token)
      {:ok, new_token} = Sessions.create()
      assert Sessions.valid?(new_token)
    end
  end
end
