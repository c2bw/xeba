defmodule Xeba.Repo.Migrations.AddEmojiListToChatStickers do
  use Ecto.Migration

  def change do
    alter table(:chat_stickers) do
      add :emoji_list, {:array, :string}, null: false, default: []
    end

    execute(
      "UPDATE chat_stickers SET emoji_list = ARRAY[emoji] WHERE emoji IS NOT NULL AND emoji != ''",
      "UPDATE chat_stickers SET emoji_list = ARRAY[]::varchar[]"
    )
  end
end
