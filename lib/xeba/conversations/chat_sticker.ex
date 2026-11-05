defmodule Xeba.Conversations.ChatSticker do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_stickers" do
    field :chat_id, :integer
    field :sticker_id, :string
    field :file_unique_id, :string
    field :content_hash, :binary
    field :sticker_ids, {:array, :string}, default: []
    field :emoji, :string
    field :emoji_list, {:array, :string}, default: []
    field :data, :binary
    field :last_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(chat_sticker, attrs) do
    chat_sticker
    |> cast(attrs, [
      :chat_id,
      :sticker_id,
      :file_unique_id,
      :content_hash,
      :sticker_ids,
      :emoji,
      :emoji_list,
      :data,
      :last_seen_at
    ])
    |> validate_required([:chat_id, :sticker_id, :last_seen_at])
    |> unique_constraint(:file_unique_id, name: :chat_stickers_chat_id_file_unique_id_index)
    |> unique_constraint(:content_hash, name: :chat_stickers_legacy_content_index)
    |> unique_constraint(:sticker_id, name: :chat_stickers_chat_id_sticker_id_index)
  end
end
