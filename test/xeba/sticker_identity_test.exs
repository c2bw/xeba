defmodule Xeba.StickerIdentityTest do
  use Xeba.DataCase, async: true

  alias Xeba.Conversations
  alias Xeba.Conversations.{ChatSticker, Exchange}
  alias Xeba.Repo

  test "rotating file IDs update one stable identity and keep the latest sendable ID" do
    {:ok, first} = record("first", "file-1", "unique-1", bytes("one"))
    [original] = Conversations.list_chat_stickers(42)
    {:ok, latest} = record("second", "file-2", "unique-1", nil)
    [sticker] = Conversations.list_chat_stickers(42)
    assert sticker.id == original.id
    assert sticker.file_unique_id == "unique-1"
    assert sticker.sticker_id == "file-2"
    assert Enum.sort(sticker.sticker_ids) == ["file-1", "file-2"]
    assert sticker.data == bytes("one")
    assert first.file_unique_id == "unique-1"
    assert latest.file_unique_id == "unique-1"
    assert Repo.aggregate(Exchange, :count) == 2
    assert [%{sticker_id: "file-2"}] = Conversations.sticker_candidates_for_emoji(42, "🔥")
  end

  test "legacy file IDs remain aliases after rotation and do not clear stable identity" do
    {:ok, _} = record("first", "file-1", "unique-1", bytes("one"))
    {:ok, _} = record("second", "file-2", "unique-1", nil)
    {:ok, _} = record("legacy", "file-1", nil, nil)
    [sticker] = Conversations.list_chat_stickers(42)
    assert sticker.file_unique_id == "unique-1"
    assert sticker.data == bytes("one")
    assert sticker.sticker_id == "file-1"
  end

  test "legacy content duplicates collapse and are promoted when a unique ID arrives" do
    {:ok, first} = record("first", "legacy-1", nil, bytes("one"))
    [original] = Conversations.list_chat_stickers(42)
    {:ok, _} = record("second", "legacy-2", nil, bytes("one"))
    [legacy] = Conversations.list_chat_stickers(42)
    assert legacy.id == original.id
    assert legacy.file_unique_id == nil
    {:ok, _} = record("third", "current", "unique-1", bytes("one"))
    [promoted] = Conversations.list_chat_stickers(42)
    assert promoted.id == original.id
    assert promoted.file_unique_id == "unique-1"
    assert Enum.sort(promoted.sticker_ids) == ["current", "legacy-1", "legacy-2"]
    assert Repo.get!(Exchange, first.id).sticker_id == "legacy-1"
    assert Repo.get!(Exchange, first.id).sticker_data == bytes("one")
  end

  test "a known identity merges with a legacy reference without losing payload or emoji metadata" do
    {:ok, _} = record("identified", "known", "unique-1", nil)
    [known] = Conversations.list_chat_stickers(42)

    {:ok, _} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "legacy",
          chat_id: 42,
          datatype: "file",
          sticker_id: "legacy",
          data: bytes("one"),
          sticker_emoji: "🎉",
          emoji_list: ["🎉"]
        },
        "test"
      )

    assert length(Conversations.list_chat_stickers(42)) == 2
    {:ok, _} = record("join", "legacy", "unique-1", nil)
    [merged] = Conversations.list_chat_stickers(42)
    assert merged.id == known.id
    assert merged.sticker_id == "legacy"
    assert merged.data == bytes("one")
    assert Enum.sort(merged.emoji_list) == Enum.sort(["🔥", "🎉"])
    assert Conversations.sticker_page(42).total == 1
  end

  test "distinct authoritative IDs are preserved even for identical bytes, and chats stay separate" do
    {:ok, _} = record("first", "file-1", "unique-1", bytes("same"))
    {:ok, _} = record("second", "file-2", "unique-2", bytes("same"))
    assert length(Conversations.list_chat_stickers(42)) == 2

    {:ok, _} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "other-chat",
          chat_id: 99,
          datatype: "file",
          sticker_id: "file-1",
          file_unique_id: "unique-1",
          data: bytes("same")
        },
        "test"
      )

    assert length(Conversations.list_chat_stickers(99)) == 1
  end

  test "ambiguous content without an identity does not merge distinct known identities" do
    {:ok, _} = record("first", "file-1", "unique-1", bytes("same"))
    {:ok, _} = record("second", "file-2", "unique-2", bytes("same"))
    {:ok, _} = record("legacy", "file-3", nil, bytes("same"))
    assert length(Conversations.list_chat_stickers(42)) == 3
    {:ok, _} = record("identify", "file-3", "unique-1", nil)
    assert length(Conversations.list_chat_stickers(42)) == 2
  end

  test "an authoritative ID can split an alias previously matched only by legacy content" do
    {:ok, _} = record("known", "file-1", "unique-1", bytes("same"))
    {:ok, _} = record("legacy", "file-2", nil, bytes("same"))
    assert length(Conversations.list_chat_stickers(42)) == 1
    {:ok, _} = record("identified-later", "file-2", "unique-2", nil)
    stickers = Conversations.list_chat_stickers(42)
    assert length(stickers) == 2
    assert Enum.sort(Enum.map(stickers, & &1.file_unique_id)) == ["unique-1", "unique-2"]
    assert Enum.all?(stickers, &(&1.data == bytes("same")))
    first = Enum.find(stickers, &(&1.file_unique_id == "unique-1"))
    assert first.sticker_id == "file-1"
    refute "file-2" in first.sticker_ids
  end

  test "conflicting identities roll back the exchange and keep the existing bank intact" do
    {:ok, _} = record("first", "same-file", "unique-1", bytes("one"))
    assert {:error, changeset} = record("bad", "same-file", "unique-2", bytes("two"))
    assert changeset.errors[:file_unique_id]
    assert Repo.aggregate(Exchange, :count) == 1
    [sticker] = Conversations.list_chat_stickers(42)
    assert sticker.file_unique_id == "unique-1"
    assert sticker.data == bytes("one")
  end

  test "the database enforces stable identities within a chat" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%ChatSticker{
      chat_id: 42,
      sticker_id: "file-1",
      file_unique_id: "unique-1",
      last_seen_at: now
    })

    changeset =
      ChatSticker.changeset(%ChatSticker{}, %{
        chat_id: 42,
        sticker_id: "file-2",
        file_unique_id: "unique-1",
        last_seen_at: now
      })

    assert {:error, changeset} = Repo.insert(changeset)
    assert changeset.errors[:file_unique_id]
  end

  defp record(req, file_id, unique_id, data) do
    Conversations.create_from_message(
      %ExironClient.Message{
        req_id: req,
        chat_id: 42,
        datatype: if(data, do: "file", else: "sticker"),
        sticker_id: file_id,
        file_unique_id: unique_id,
        data: data || file_id,
        sticker_emoji: "🔥",
        emoji_list: ["🔥"]
      },
      "test"
    )
  end

  defp bytes(suffix), do: <<"RIFF", 0, 0, 0, 0, "WEBP">> <> suffix
end
