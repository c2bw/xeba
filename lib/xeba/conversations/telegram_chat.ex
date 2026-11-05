defmodule Xeba.Conversations.TelegramChat do
  use Ecto.Schema
  import Ecto.Changeset

  schema "telegram_chats" do
    field :chat_id, :integer
    field :name, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(chat, attrs) do
    chat
    |> cast(attrs, [:chat_id, :name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:chat_id, :name])
    |> validate_length(:name, max: 255)
    |> unique_constraint(:chat_id)
  end
end
