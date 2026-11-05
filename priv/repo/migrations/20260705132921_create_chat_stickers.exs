defmodule Xeba.Repo.Migrations.CreateChatStickers do
  use Ecto.Migration

  def change do
    create table(:chat_stickers) do
      add :chat_id, :bigint, null: false
      add :sticker_id, :string, null: false
      add :emoji, :string
      add :data, :binary
      add :last_seen_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chat_stickers, [:chat_id, :sticker_id])
  end
end
