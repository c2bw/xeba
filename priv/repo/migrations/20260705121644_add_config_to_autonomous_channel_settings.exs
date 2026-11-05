defmodule Xeba.Repo.Migrations.AddConfigToAutonomousChannelSettings do
  use Ecto.Migration

  def change do
    alter table(:autonomous_channel_settings) do
      add :context_window, :integer, null: false, default: 20
      add :message_trigger, :integer, null: false, default: 25
    end
  end
end
