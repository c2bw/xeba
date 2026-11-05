defmodule Xeba.Conversations.Exchange do
  use Ecto.Schema
  import Ecto.Changeset

  schema "exchanges" do
    field :delivery_state, :map, default: %{}
    field :req_id, :string
    field :msgtype, :string, default: "request"
    field :message_id, :integer
    field :reply_to_message_id, :integer
    field :message_thread_id, :integer
    field :service_id, :integer
    field :chat_id, :integer
    field :sender_id, :integer
    field :sender_is_bot, :boolean
    field :sender_first_name, :string
    field :sender_last_name, :string
    field :sender_username, :string
    field :sender_language_code, :string
    field :datatype, :string
    field :file_unique_id, :string
    field :sticker_id, :string
    field :sticker_emoji, :string
    field :emoji_list, {:array, :string}, virtual: true, default: []
    field :sticker_data_prefix, :binary, virtual: true
    field :sticker_data, :binary
    field :request_text, :string
    field :response_text, :string
    field :model, :string
    field :status, :string, default: "pending"
    field :error, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :total_tokens, :integer
    field :tokens_used_at, :utc_datetime_usec
    field :latency_ms, :integer
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(exchange, attrs) do
    exchange
    |> cast(attrs, [
      :delivery_state,
      :req_id,
      :msgtype,
      :message_id,
      :reply_to_message_id,
      :message_thread_id,
      :service_id,
      :chat_id,
      :sender_id,
      :sender_is_bot,
      :sender_first_name,
      :sender_last_name,
      :sender_username,
      :sender_language_code,
      :datatype,
      :sticker_id,
      :file_unique_id,
      :sticker_emoji,
      :emoji_list,
      :sticker_data,
      :request_text,
      :response_text,
      :model,
      :status,
      :error,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :tokens_used_at,
      :latency_ms,
      :completed_at
    ])
    |> validate_required([:msgtype, :datatype, :status])
    |> unique_constraint(:req_id)
    |> unique_constraint(:message_id, name: :exchanges_telegram_message_identity_index)
  end
end
