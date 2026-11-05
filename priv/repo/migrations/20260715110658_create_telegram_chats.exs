defmodule Xeba.Repo.Migrations.CreateTelegramChats do
  use Ecto.Migration

  def change do
    create table(:telegram_chats) do
      add :chat_id, :bigint, null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:telegram_chats, [:chat_id])
  end
end
