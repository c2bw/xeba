defmodule Xeba.Conversations.AutonomousChannelSetting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "autonomous_channel_settings" do
    field :chat_id, :integer
    field :enabled, :boolean, default: true
    field :context_window, :integer, default: 20
    field :message_trigger, :integer, default: 25
    field :system_prompt, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:enabled, :context_window, :message_trigger, :system_prompt])
    |> validate_required([:chat_id, :enabled, :context_window, :message_trigger])
    |> validate_number(:context_window,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> validate_number(:message_trigger,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 500
    )
    |> validate_length(:system_prompt, min: 1, max: 20_000)
    |> unique_constraint(:chat_id)
  end
end
