defmodule Xeba.Repo.Migrations.CreateAutonomousChannelSettings do
  use Ecto.Migration

  def change do
    create table(:autonomous_channel_settings) do
      add :chat_id, :bigint, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:autonomous_channel_settings, [:chat_id])
  end
end
