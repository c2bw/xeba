defmodule Xeba.Repo.Migrations.AddStickerDataToExchanges do
  use Ecto.Migration

  def change do
    alter table(:exchanges) do
      add :sticker_id, :string
      add :sticker_data, :binary
    end
  end
end
