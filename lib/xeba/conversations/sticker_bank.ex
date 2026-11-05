defmodule Xeba.Conversations.StickerBank do
  @moduledoc "Per-chat sticker identity, legacy promotion, and file-ID aliases."
  import Ecto.Query

  alias Xeba.Conversations.{ChatSticker, Exchange}
  alias Xeba.Repo

  def record(%{chat_id: chat_id, sticker_id: id} = exchange)
      when is_integer(chat_id) and is_binary(id) and id != "" do
    Repo.transaction(fn ->
      # Serialize identity promotion and merging, including across app instances.
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        ["xeba:stickers:#{chat_id}"],
        log: false
      )

      unique_id = nonblank(exchange.file_unique_id)

      primary =
        Repo.all(
          from s in ChatSticker,
            where:
              s.chat_id == ^chat_id and
                (s.sticker_id == ^id or
                   fragment("? @> ARRAY[?]::varchar[]", s.sticker_ids, ^id)),
            order_by: [desc: s.last_seen_at, desc: s.id]
        )

      identified =
        if unique_id,
          do:
            Repo.all(
              from s in ChatSticker,
                where: s.chat_id == ^chat_id and s.file_unique_id == ^unique_id
            ),
          else: []

      primary = Enum.uniq_by(identified ++ primary, & &1.id)
      data = nonempty(exchange.sticker_data) || Enum.find_value(primary, &nonempty(&1.data))
      primary = reconcile_aliases(primary, unique_id, exchange)

      hash =
        if data,
          do: :crypto.hash(:sha256, data),
          else: Enum.find_value(primary, & &1.content_hash)

      matches =
        if hash,
          do:
            Repo.all(
              from s in ChatSticker,
                where: s.chat_id == ^chat_id and s.content_hash == ^hash,
                order_by: [desc: s.last_seen_at, desc: s.id]
            ),
          else: []

      candidates = matching_rows(primary, matches, unique_id)
      save(exchange, unique_id, data, candidates)
    end)
  end

  def record(_exchange), do: :ignore

  defp matching_rows(primary, matches, unique_id) do
    known_ids =
      Enum.map(primary ++ matches, & &1.file_unique_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    allowed_id =
      unique_id || Enum.find_value(primary, & &1.file_unique_id) ||
        if(length(known_ids) == 1, do: hd(known_ids))

    matches =
      Enum.filter(matches, fn row ->
        is_nil(row.file_unique_id) or row.file_unique_id == allowed_id
      end)

    Enum.uniq_by(primary ++ matches, & &1.id)
  end

  defp reconcile_aliases(rows, nil, exchange) do
    known_ids = Enum.map(rows, & &1.file_unique_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    if length(known_ids) > 1, do: identity_conflict!(exchange)
    rows
  end

  defp reconcile_aliases(rows, unique_id, exchange) do
    Enum.filter(rows, fn row ->
      if row.file_unique_id in [nil, unique_id] do
        true
      else
        proven? =
          Repo.exists?(
            from e in Exchange,
              where:
                e.chat_id == ^exchange.chat_id and e.sticker_id == ^exchange.sticker_id and
                  e.file_unique_id == ^row.file_unique_id and e.id != ^exchange.id
          )

        aliases = Enum.uniq([row.sticker_id | row.sticker_ids]) -- [exchange.sticker_id]
        if proven? or aliases == [], do: identity_conflict!(exchange)

        # A legacy content match is provisional. An explicit Telegram identity
        # can split its alias back out without combining distinct known IDs.
        current_id =
          if row.sticker_id == exchange.sticker_id, do: hd(aliases), else: row.sticker_id

        row
        |> ChatSticker.changeset(%{sticker_id: current_id, sticker_ids: aliases})
        |> Repo.update!()

        false
      end
    end)
  end

  defp identity_conflict!(exchange) do
    changeset =
      %ChatSticker{chat_id: exchange.chat_id}
      |> ChatSticker.changeset(%{sticker_id: exchange.sticker_id})
      |> Ecto.Changeset.add_error(:file_unique_id, "conflicts with the existing sticker identity")

    Repo.rollback(changeset)
  end

  defp save(exchange, unique_id, incoming_data, rows) do
    # Prefer an identified row so its media URL remains stable during promotion.
    canonical =
      Enum.find(rows, &(not is_nil(&1.file_unique_id))) || List.first(rows) || %ChatSticker{}

    others = Enum.reject(rows, &(&1.id == canonical.id))

    data =
      incoming_data || nonempty(canonical.data) || Enum.find_value(others, &nonempty(&1.data))

    emojis = emoji_list(exchange)
    emojis = if emojis == [], do: canonical.emoji_list, else: emojis
    emojis = Enum.uniq(emojis ++ Enum.flat_map(others, & &1.emoji_list))

    ids =
      Enum.uniq([exchange.sticker_id] ++ Enum.flat_map(rows, &[&1.sticker_id | &1.sticker_ids]))

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      chat_id: exchange.chat_id,
      sticker_id: exchange.sticker_id,
      file_unique_id: unique_id || canonical.file_unique_id,
      sticker_ids: ids,
      data: data,
      content_hash: if(data, do: :crypto.hash(:sha256, data)),
      emoji:
        nonblank(exchange.sticker_emoji) || canonical.emoji || Enum.find_value(others, & &1.emoji),
      emoji_list: emojis,
      last_seen_at: now
    }

    # Remove merged rows before changing the canonical row's current file ID.
    removed_ids = Enum.map(others, & &1.id)
    Repo.delete_all(from s in ChatSticker, where: s.id in ^removed_ids)
    inserted_at = Enum.map(rows, & &1.inserted_at) |> Enum.min(DateTime, fn -> now end)

    changeset =
      canonical
      |> ChatSticker.changeset(attrs)
      |> Ecto.Changeset.put_change(:inserted_at, inserted_at)

    case Repo.insert_or_update(changeset) do
      {:ok, sticker} -> sticker
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp emoji_list(exchange) do
    metadata = if is_list(exchange.emoji_list), do: exchange.emoji_list, else: []

    ([exchange.sticker_emoji] ++ metadata)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp nonblank(_value), do: nil

  defp nonempty(value) when is_binary(value) and value != "", do: value
  defp nonempty(_value), do: nil
end
