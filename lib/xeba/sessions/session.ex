defmodule Xeba.Sessions.Session do
  use Ecto.Schema

  schema "sessions" do
    field :token_hash, :binary
    field :credentials_version, :binary
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
