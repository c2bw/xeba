defmodule Xeba.Repo.Migrations.CreateExchanges do
  use Ecto.Migration

  def change do
    create table(:exchanges) do
      add :req_id, :string, null: false
      add :message_id, :bigint
      add :reply_to_message_id, :bigint
      add :service_id, :bigint
      add :chat_id, :bigint
      add :datatype, :string, null: false
      add :request_text, :text
      add :response_text, :text
      add :model, :string
      add :status, :string, null: false, default: "pending"
      add :error, :text
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :total_tokens, :integer
      add :latency_ms, :integer
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:exchanges, [:req_id])
    create index(:exchanges, [:chat_id, :completed_at])
    create index(:exchanges, [:inserted_at])
  end
end
