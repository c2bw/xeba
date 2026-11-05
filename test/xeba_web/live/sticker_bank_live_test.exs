defmodule XebaWeb.StickerBankLiveTest do
  use XebaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Xeba.Conversations

  test "renders an empty sticker bank", %{conn: conn} do
    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/404/stickers")

    assert has_element?(view, "#sticker-bank-chat-heading", "Chat 404")
    assert has_element?(view, "#sticker-bank-count", "0 stickers")
    assert has_element?(view, "#sticker-bank-empty")
    assert has_element?(view, "#sticker-bank-console-link")
    assert has_element?(view, "#sticker-bank-transcript-link")
  end

  test "renders static and animated stickers for the selected chat", %{conn: conn} do
    static = create_sticker("static-sticker", 42, "fire", ["fire", "laugh"], webp_sticker_data())
    animated = create_sticker("animated-sticker", 42, "dance", ["dance"], webm_sticker_data())
    other = create_sticker("other-chat", 99, "skip", ["skip"], webp_sticker_data())

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/42/stickers")

    assert has_element?(view, "#sticker-bank-count", "2 stickers")
    assert has_element?(view, "#sticker-bank-item-#{static.id}")
    assert has_element?(view, "#sticker-bank-id-#{static.id}", "static-sticker")
    assert has_element?(view, "#sticker-bank-emoji-#{static.id}", "fire laugh")

    assert has_element?(
             view,
             "#sticker-bank-media-#{static.id}[src='/chats/42/stickers/#{static.id}/media'][loading='lazy']"
           )

    assert has_element?(view, "#sticker-bank-item-#{animated.id}")
    assert has_element?(view, "#sticker-bank-id-#{animated.id}", "animated-sticker")
    assert has_element?(view, "#sticker-bank-emoji-#{animated.id}", "dance")
    assert has_element?(view, "#sticker-bank-media-#{animated.id} source[type='video/webm']")

    refute has_element?(view, "#sticker-bank-id-#{other.id}", "other-chat")

    view
    |> element("#sticker-bank-filter-form")
    |> render_change(%{filter: %{emoji: "laugh"}})

    assert has_element?(view, "#sticker-bank-filter-count", "1 matched")
    assert has_element?(view, "#sticker-bank-emoji-filter[phx-debounce='250']")
    assert has_element?(view, "#sticker-bank-item-#{static.id}")
    refute has_element?(view, "#sticker-bank-item-#{animated.id}")
  end

  test "shows one stable identity and an expandable full file ID", %{conn: conn} do
    prefix = "CAACAgIAAxkBAA" <> String.duplicate("a", 100)

    for {request_id, file_id} <- [
          {"identity-old", prefix <> "old"},
          {"identity-new", prefix <> "new"}
        ] do
      {:ok, _} =
        Conversations.create_from_message(
          %ExironClient.Message{
            req_id: request_id,
            chat_id: 42,
            datatype: "file",
            sticker_id: file_id,
            file_unique_id: "stable-telegram-id",
            data: webp_sticker_data(),
            sticker_emoji: "🔥"
          },
          "test"
        )
    end

    [sticker] = Conversations.list_chat_stickers(42)
    {:ok, view, _} = live(log_in_user(conn), ~p"/chats/42/stickers")
    assert has_element?(view, "#sticker-bank-count", "1 stickers")
    assert has_element?(view, "#sticker-bank-unique-id-#{sticker.id}", "stable-telegram-id")
    assert has_element?(view, "#sticker-bank-file-id-#{sticker.id} summary", "Telegram file ID")
    assert has_element?(view, "#sticker-bank-file-id-#{sticker.id} code", prefix <> "new")
  end

  test "shows the Telegram chat name beside its ID", %{conn: conn} do
    assert {:ok, _chat} = Conversations.remember_chat_name(42, "Xeba Lounge")

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/42/stickers")

    assert has_element?(view, "#sticker-bank-chat-heading", "Xeba Lounge / chat:42")
    assert has_element?(view, "#sticker-bank-chat-name", "Xeba Lounge")
  end

  test "paginates metadata and filters the whole bank in SQL", %{conn: conn} do
    stickers =
      for index <- 1..25 do
        create_sticker(
          "paged-#{index}",
          501,
          if(index == 1, do: "rare", else: "common"),
          [if(index == 1, do: "rare", else: "common")],
          webp_sticker_data()
        )
      end

    oldest = hd(stickers)
    newest = List.last(stickers)
    page = Conversations.sticker_page(501)
    assert length(page.stickers) == 24
    assert page.total == 25
    assert page.pages == 2

    assert Enum.all?(
             page.stickers,
             &(not Map.has_key?(&1, :data) and byte_size(&1.data_prefix) <= 12)
           )

    {:ok, view, _} = live(log_in_user(conn), ~p"/chats/501/stickers")
    assert has_element?(view, "#sticker-bank-page-number", "Page 1 of 2")
    assert has_element?(view, "#sticker-bank-item-#{newest.id}")
    refute has_element?(view, "#sticker-bank-item-#{oldest.id}")
    view |> element("#sticker-bank-next-page") |> render_click()
    assert has_element?(view, "#sticker-bank-item-#{oldest.id}")
    refute has_element?(view, "#sticker-bank-item-#{newest.id}")
    view |> element("#sticker-bank-filter-form") |> render_change(%{filter: %{emoji: "common"}})
    assert has_element?(view, "#sticker-bank-filter-count", "24 matched")
    assert has_element?(view, "#sticker-bank-item-#{newest.id}")
    refute has_element?(view, "#sticker-bank-item-#{oldest.id}")
    refute has_element?(view, "#sticker-bank-next-page")
    view |> element("#sticker-bank-filter-form") |> render_change(%{filter: %{emoji: "rare"}})
    assert has_element?(view, "#sticker-bank-item-#{oldest.id}")
    assert has_element?(view, "#sticker-bank-filter-count", "1 matched")
  end

  test "links to the sticker bank from a selected chat", %{conn: conn} do
    {:ok, _exchange} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "link-chat",
          chat_id: 42,
          datatype: "text",
          data: "hello"
        },
        "cerebras:test"
      )

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/42")

    assert has_element?(view, "#chat-sticker-bank-link")
  end

  defp create_sticker(sticker_id, chat_id, emoji, emoji_list, data) do
    {:ok, _exchange} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: sticker_id,
          chat_id: chat_id,
          datatype: "file",
          sticker_id: sticker_id,
          sticker_emoji: emoji,
          emoji_list: emoji_list,
          data: data <> sticker_id
        },
        "cerebras:test"
      )

    Conversations.list_chat_stickers(chat_id)
    |> Enum.find(&(&1.sticker_id == sticker_id))
  end

  defp webp_sticker_data, do: <<"RIFF", 0, 0, 0, 0, "WEBP", "static">>
  defp webm_sticker_data, do: <<0x1A, 0x45, 0xDF, 0xA3, "animated">>
end
