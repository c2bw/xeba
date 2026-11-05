defmodule Xeba.Conversations.OutgoingMessage do
  use Ecto.Schema

  schema "outgoing_telegram_messages" do
    belongs_to :exchange, Xeba.Conversations.Exchange
    field :service_id, :integer
    field :chat_id, :integer
    field :message_id, :integer
    field :message_thread_id, :integer
    field :part, :string
    field :text, :string, virtual: true
    timestamps(type: :utc_datetime)
  end
end
