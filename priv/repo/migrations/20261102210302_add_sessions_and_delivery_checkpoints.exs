defmodule Xeba.Repo.Migrations.AddSessionsAndDeliveryCheckpoints do
  use Ecto.Migration

  def change do
    create table(:sessions) do
      add :token_hash, :binary, null: false
      add :credentials_version, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:sessions, [:token_hash])
    create index(:sessions, [:expires_at])

    alter table(:exchanges) do
      add :delivery_state, :map, null: false, default: %{}
    end

    create index(:exchanges, [:chat_id, :inserted_at, :id])
  end
end
