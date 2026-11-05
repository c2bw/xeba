defmodule Xeba.Repo.Migrations.DeduplicateStickerBankByFileIdentity do
  use Ecto.Migration

  def up do
    alter table(:exchanges) do
      add :file_unique_id, :string
    end

    alter table(:chat_stickers) do
      add :file_unique_id, :string
      add :content_hash, :binary
      add :sticker_ids, {:array, :string}, null: false, default: []
    end

    flush()

    execute "UPDATE chat_stickers SET sticker_ids = ARRAY[sticker_id]"
    execute "UPDATE chat_stickers SET content_hash = sha256(data) WHERE octet_length(data) > 0"

    execute """
    CREATE TEMP TABLE xeba_sticker_merge ON COMMIT DROP AS
    SELECT id, first_value(id) OVER (
      PARTITION BY chat_id, content_hash ORDER BY last_seen_at DESC, id DESC
    ) AS keeper_id
    FROM chat_stickers WHERE content_hash IS NOT NULL
    """

    execute """
    UPDATE chat_stickers AS keeper SET
      sticker_ids = ARRAY(
        SELECT DISTINCT source.sticker_id
        FROM chat_stickers source JOIN xeba_sticker_merge m ON m.id = source.id
        WHERE m.keeper_id = keeper.id ORDER BY source.sticker_id
      ),
      emoji_list = ARRAY(
        SELECT DISTINCT emoji FROM (
          SELECT unnest(source.emoji_list ||
            CASE WHEN source.emoji IS NULL THEN ARRAY[]::varchar[] ELSE ARRAY[source.emoji] END) AS emoji
          FROM chat_stickers source JOIN xeba_sticker_merge m ON m.id = source.id
          WHERE m.keeper_id = keeper.id
        ) values WHERE emoji IS NOT NULL AND emoji <> '' ORDER BY emoji
      ),
      emoji = COALESCE(keeper.emoji, (
        SELECT source.emoji FROM chat_stickers source JOIN xeba_sticker_merge m ON m.id = source.id
        WHERE m.keeper_id = keeper.id AND source.emoji IS NOT NULL
        ORDER BY source.last_seen_at DESC, source.id DESC LIMIT 1
      )),
      inserted_at = (
        SELECT min(source.inserted_at) FROM chat_stickers source
        JOIN xeba_sticker_merge m ON m.id = source.id WHERE m.keeper_id = keeper.id
      )
    WHERE keeper.id IN (SELECT keeper_id FROM xeba_sticker_merge)
    """

    execute """
    DELETE FROM chat_stickers source USING xeba_sticker_merge m
    WHERE source.id = m.id AND m.id <> m.keeper_id
    """

    create unique_index(:chat_stickers, [:chat_id, :file_unique_id])

    create unique_index(:chat_stickers, [:chat_id, :content_hash],
             name: :chat_stickers_legacy_content_index,
             where: "file_unique_id IS NULL AND content_hash IS NOT NULL"
           )

    create index(:chat_stickers, [:sticker_ids], using: :gin)
  end

  def down do
    drop index(:chat_stickers, [:sticker_ids])

    drop index(:chat_stickers, [:chat_id, :content_hash],
           name: :chat_stickers_legacy_content_index
         )

    drop index(:chat_stickers, [:chat_id, :file_unique_id])

    alter table(:chat_stickers) do
      remove :sticker_ids
      remove :content_hash
      remove :file_unique_id
    end

    alter table(:exchanges) do
      remove :file_unique_id
    end
  end
end
