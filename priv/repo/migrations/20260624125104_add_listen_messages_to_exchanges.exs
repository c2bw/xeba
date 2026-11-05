defmodule Xeba.Repo.Migrations.AddListenMessagesToExchanges do
  use Ecto.Migration

  def change do
    alter table(:exchanges) do
      add :msgtype, :string, null: false, default: "request"
      modify :req_id, :string, null: true
    end

    create unique_index(:exchanges, [:service_id, :chat_id, :message_id, :msgtype],
             where: "message_id IS NOT NULL",
             name: :exchanges_telegram_message_identity_index
           )
  end
end
