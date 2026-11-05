defmodule Xeba.StickerStorageTest do
  use Xeba.DataCase, async: true
  alias Xeba.Conversations

  test "a sticker with no emoji still retains its downloaded media" do
    data = <<"RIFF", 0, 0, 0, 0, "WEBP", "first">>
    {:ok, exchange} = Conversations.create_from_message(message("without-emoji", data), "test")
    assert exchange.sticker_data == data
    [sticker] = Conversations.list_chat_stickers(702)
    assert sticker.data == data
    assert sticker.emoji == nil
    assert sticker.emoji_list == []
  end

  test "metadata-only observations preserve valid media and emoji metadata" do
    data = <<"RIFF", 0, 0, 0, 0, "WEBP", "first">>
    full = %{message("full", data) | sticker_emoji: "🔥", emoji_list: ["🔥", "🎉"]}
    {:ok, _} = Conversations.create_from_message(full, "test")

    for {req, datatype, payload} <- [
          {"reference", "sticker", "shared-sticker"},
          {"empty", "file", ""}
        ] do
      {:ok, _} =
        Conversations.create_from_message(%{message(req, payload) | datatype: datatype}, "test")

      [sticker] = Conversations.list_chat_stickers(702)
      assert sticker.data == data
      assert sticker.emoji == "🔥"
      assert sticker.emoji_list == ["🔥", "🎉"]
    end

    replacement = <<0x1A, 0x45, 0xDF, 0xA3, "new video">>
    {:ok, exchange} = Conversations.create_from_message(message("new-data", replacement), "test")
    assert exchange.sticker_data == replacement
    [sticker] = Conversations.list_chat_stickers(702)
    assert sticker.data == replacement
    assert sticker.emoji_list == ["🔥", "🎉"]
    assert sticker.emoji == "🔥"
  end

  defp message(req_id, data) do
    %ExironClient.Message{
      req_id: req_id,
      chat_id: 702,
      datatype: "file",
      sticker_id: "shared-sticker",
      sticker_emoji: nil,
      emoji_list: [],
      data: data
    }
  end
end
