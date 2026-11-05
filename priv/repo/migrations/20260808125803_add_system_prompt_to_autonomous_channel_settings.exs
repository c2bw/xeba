defmodule Xeba.Repo.Migrations.AddSystemPromptToAutonomousChannelSettings do
  use Ecto.Migration

  def change do
    alter table(:autonomous_channel_settings) do
      add :system_prompt, :text
    end
  end
end
