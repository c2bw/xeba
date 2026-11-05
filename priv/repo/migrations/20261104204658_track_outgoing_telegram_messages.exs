defmodule Xeba.Repo.Migrations.TrackOutgoingTelegramMessages do
  use Ecto.Migration

  def change do
    alter table(:exchanges) do
      add :message_thread_id, :bigint
    end

    create table(:outgoing_telegram_messages) do
      add :exchange_id, references(:exchanges, on_delete: :delete_all), null: false
      add :service_id, :bigint, null: false
      add :chat_id, :bigint, null: false
      add :message_id, :bigint, null: false
      add :message_thread_id, :bigint
      add :part, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:outgoing_telegram_messages, [:service_id, :chat_id, :message_id])
    create index(:outgoing_telegram_messages, [:exchange_id])
  end
end
