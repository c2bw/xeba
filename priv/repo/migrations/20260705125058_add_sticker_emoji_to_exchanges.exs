defmodule Xeba.Repo.Migrations.AddStickerEmojiToExchanges do
  use Ecto.Migration

  def change do
    alter table(:exchanges) do
      add :sticker_emoji, :string
    end
  end
end
