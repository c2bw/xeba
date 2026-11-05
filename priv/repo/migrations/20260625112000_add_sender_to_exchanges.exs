defmodule Xeba.Repo.Migrations.AddSenderToExchanges do
  use Ecto.Migration

  def change do
    alter table(:exchanges) do
      add :sender_id, :bigint
      add :sender_is_bot, :boolean
      add :sender_first_name, :string
      add :sender_last_name, :string
      add :sender_username, :string
      add :sender_language_code, :string
    end
  end
end
