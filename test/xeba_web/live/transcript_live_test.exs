defmodule XebaWeb.TranscriptLiveTest do
  use XebaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Xeba.Conversations
  alias Xeba.Repo

  test "renders an empty transcript for a chat", %{conn: conn} do
    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/404/transcript")

    assert has_element?(view, "#transcript-chat-heading", "Chat 404")
    assert has_element?(view, "#transcript-empty")
    assert has_element?(view, "#transcript-message-count", "0 messages")
    assert has_element?(view, "#transcript-message-count", "0 bot messages")
    assert has_element?(view, "#transcript-message-count", "0 tokens")
    assert has_element?(view, "#transcript-console-link")
  end

  test "malformed date query values fall back to the latest transcript day", %{conn: conn} do
    exchange = create_exchange("bad-day", 42, "Ada", "Latest message", nil)

    for query <- [
          "day[]=2026-11-03",
          "day[value]=2026-11-03",
          "day=invalid",
          "day=2026-02-30",
          "day=-9999-01-01"
        ] do
      {:ok, view, _} = live(log_in_user(conn), "/chats/42/transcript?" <> query)
      assert has_element?(view, "#transcript-message-#{exchange.id}-user", "Latest message")
    end
  end

  test "literal sticker-like text remains a regular message", %{conn: conn} do
    exchange = create_exchange("sticker-text", 42, "Ada", "[sticker this is text]", nil)
    {:ok, view, _} = live(log_in_user(conn), ~p"/chats/42/transcript")

    assert has_element?(
             view,
             "#transcript-message-#{exchange.id}-user > p",
             "[sticker this is text]"
           )

    refute has_element?(view, "#transcript-message-#{exchange.id}-user-sticker")
  end

  test "groups messages from the same Europe/Rome date under one day", %{conn: conn} do
    first =
      create_exchange("same-1", 42, "Ada", "First message", "First reply", total_tokens: 37)
      |> set_inserted_at(~U[2026-06-29 08:00:00Z])

    second =
      create_exchange("same-2", 42, "Grace", "Second message", nil)
      |> set_inserted_at(~U[2026-06-29 21:30:00Z])

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/42/transcript")

    assert has_element?(view, "#transcript-date-map")
    refute has_element?(view, "#transcript-date-all")
    assert has_element?(view, "#transcript-date-2026-06-29", "Jun 29, 2026")
    assert has_element?(view, "#transcript-day-2026-06-29-heading", "Jun 29, 2026")
    assert has_element?(view, "#transcript-day-2026-06-29-count", "3 messages")
    assert has_element?(view, "#transcript-day-2026-06-29-messages")
    assert has_element?(view, "#transcript-message-#{first.id}-user", "First message")
    assert has_element?(view, "#transcript-message-#{first.id}-assistant", "First reply")
    assert has_element?(view, "#transcript-message-#{first.id}-user > p.whitespace-pre-line")
    assert has_element?(view, "#transcript-message-#{first.id}-assistant > p.whitespace-pre-line")
    assert has_element?(view, "#transcript-message-#{second.id}-user", "Second message")
    assert has_element?(view, "#transcript-message-count", "3 messages")
    assert has_element?(view, "#transcript-message-count", "1 bot message")
    assert has_element?(view, "#transcript-message-count", "37 tokens")
  end

  test "separates messages across Europe/Rome dates", %{conn: conn} do
    late_utc_same_rome_day =
      create_exchange("day-1", 77, "Ada", "Night message", nil)
      |> set_inserted_at(~U[2026-06-29 21:30:00Z])

    next_rome_day =
      create_exchange("day-2", 77, "Ada", "After midnight", nil)
      |> set_inserted_at(~U[2026-06-29 22:30:00Z])

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/77/transcript")

    assert has_element?(view, "#transcript-date-2026-06-29", "Jun 29, 2026")
    assert has_element?(view, "#transcript-date-2026-06-30", "Jun 30, 2026")
    refute has_element?(view, "#transcript-day-2026-06-29-heading")
    assert has_element?(view, "#transcript-day-2026-06-30-heading", "Jun 30, 2026")
    assert has_element?(view, "#transcript-day-2026-06-30-count", "1 message")
    refute has_element?(view, "#transcript-message-#{late_utc_same_rome_day.id}-user")
    assert has_element?(view, "#transcript-message-#{next_rome_day.id}-user")
  end

  test "selects one date from the date map", %{conn: conn} do
    first_day =
      create_exchange("pick-1", 88, "Ada", "Earlier day", nil)
      |> set_inserted_at(~U[2026-06-28 10:00:00Z])

    second_day =
      create_exchange("pick-2", 88, "Ada", "Chosen day", nil)
      |> set_inserted_at(~U[2026-06-29 10:00:00Z])

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/88/transcript")

    refute has_element?(view, "#transcript-message-#{first_day.id}-user")
    assert has_element?(view, "#transcript-message-#{second_day.id}-user", "Chosen day")

    view
    |> element("#transcript-date-2026-06-28")
    |> render_click()

    assert_patch(view, ~p"/chats/88/transcript?day=2026-06-28")
    assert has_element?(view, "#transcript-message-#{first_day.id}-user", "Earlier day")
    refute has_element?(view, "#transcript-message-#{second_day.id}-user")
    assert has_element?(view, "#transcript-message-count", "1 message")
    assert has_element?(view, "#transcript-message-count", "0 bot messages")
    assert has_element?(view, "#transcript-message-count", "0 tokens")
  end

  test "shows only the selected chat messages", %{conn: conn} do
    selected = create_exchange("selected", 100, "Ada", "Selected chat", nil)
    other = create_exchange("other", 200, "Grace", "Other chat", nil)

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/100/transcript")

    assert has_element?(view, "#transcript-message-#{selected.id}-user", "Selected chat")
    refute has_element?(view, "#transcript-message-#{other.id}-user")
  end

  test "paginates a busy day without retaining the previous page in the stream", %{conn: conn} do
    exchanges =
      for index <- 1..101 do
        create_exchange("page-#{index}", 501, "Ada", "Message #{index}", nil)
        |> set_inserted_at(~U[2026-06-29 10:00:00Z])
      end

    first = hd(exchanges)
    last = List.last(exchanges)
    {:ok, view, _} = live(log_in_user(conn), ~p"/chats/501/transcript")

    assert has_element?(view, "#transcript-page-number", "Page 1 of 2")
    assert has_element?(view, "#transcript-message-#{first.id}-user")
    refute has_element?(view, "#transcript-message-#{last.id}-user")
    view |> element("#transcript-next-page") |> render_click()
    assert has_element?(view, "#transcript-page-number", "Page 2 of 2")
    assert has_element?(view, "#transcript-message-#{last.id}-user")
    refute has_element?(view, "#transcript-message-#{first.id}-user")
    view |> element("#transcript-previous-page") |> render_click()
    assert has_element?(view, "#transcript-message-#{first.id}-user")
    refute has_element?(view, "#transcript-message-#{last.id}-user")
  end

  test "invisible autonomous rows do not consume pages before visible messages", %{conn: conn} do
    for index <- 1..100 do
      {:ok, exchange} = Conversations.create_autonomous(503, "test-model")
      {:ok, _} = Conversations.update_exchange(exchange, %{status: "no_answer"})
      set_inserted_at(exchange, DateTime.add(~U[2026-11-02 10:00:00Z], index, :second))
    end

    visible =
      create_exchange("visible-after-declined", 503, "Ada", "Visible message", nil)
      |> set_inserted_at(~U[2026-11-02 11:00:00Z])

    assert %{pages: 1, exchanges: [%{id: id}]} =
             Conversations.transcript_page(503, ~D[2026-11-02])

    assert id == visible.id
    {:ok, view, _} = live(log_in_user(conn), ~p"/chats/503/transcript")
    assert has_element?(view, "#transcript-message-#{visible.id}-user")
    refute has_element?(view, "#transcript-empty")
    refute has_element?(view, "#transcript-next-page")
  end

  test "bounds the calendar and lets older dates be reached", %{conn: conn} do
    for index <- 0..31 do
      create_exchange("calendar-#{index}", 502, "Ada", "A message", nil)
      |> set_inserted_at(DateTime.add(~U[2026-07-01 10:00:00Z], index, :day))
    end

    {:ok, view, _} = live(log_in_user(conn), ~p"/chats/502/transcript")
    assert has_element?(view, "#transcript-date-2026-08-01")
    refute has_element?(view, "#transcript-date-2026-07-01")
    view |> element("#transcript-older-dates") |> render_click()
    assert has_element?(view, "#transcript-date-2026-07-01")
    refute has_element?(view, "#transcript-date-2026-08-01")
    view |> element("#transcript-latest-date") |> render_click()
    assert has_element?(view, "#transcript-date-2026-08-01")
  end

  test "shows the Telegram chat name beside its ID", %{conn: conn} do
    _exchange = create_exchange("named-transcript", 101, "Ada", "Hello", nil)
    assert {:ok, _chat} = Conversations.remember_chat_name(101, "Xeba Lounge")

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/101/transcript")

    assert has_element?(view, "#transcript-chat-heading", "Xeba Lounge / chat:101")
    assert has_element?(view, "#transcript-chat-name", "Xeba Lounge")
  end

  test "renders unsupported requests and autonomous replies", %{conn: conn} do
    unsupported =
      create_exchange("photo", 300, "Ada", nil, nil, datatype: "photo")

    autonomous =
      Conversations.create_autonomous(300, "cerebras:test")
      |> then(fn {:ok, exchange} ->
        Conversations.update_exchange(exchange, %{
          response_text: "Autonomous hello",
          status: "completed"
        })
      end)
      |> then(fn {:ok, exchange} -> exchange end)

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/300/transcript")

    assert has_element?(view, "#transcript-message-#{unsupported.id}-user", "[photo message]")

    assert has_element?(
             view,
             "#transcript-message-#{autonomous.id}-assistant",
             "Autonomous hello"
           )
  end

  test "renders sticker requests with their emoji metadata", %{conn: conn} do
    sticker =
      create_exchange("sticker", 301, "Ada", nil, nil,
        datatype: "file",
        sticker_id: "telegram-sticker-id",
        sticker_emoji: "fire",
        data: webp_sticker_data()
      )

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/301/transcript")

    assert has_element?(view, "#transcript-message-#{sticker.id}-user", "[sticker fire]")

    assert has_element?(
             view,
             "#transcript-message-#{sticker.id}-user-sticker[src='/chats/301/exchanges/#{sticker.id}/media'][loading='lazy']"
           )

    assert has_element?(
             view,
             "#transcript-message-#{sticker.id}-user-sticker-id",
             "telegram-sticker-id"
           )
  end

  test "renders animated sticker requests", %{conn: conn} do
    sticker =
      create_exchange("animated-sticker", 302, "Ada", nil, nil,
        datatype: "file",
        sticker_id: "animated-sticker-id",
        sticker_emoji: "dance",
        data: webm_sticker_data()
      )

    {:ok, view, _html} = live(log_in_user(conn), ~p"/chats/302/transcript")

    assert has_element?(
             view,
             "#transcript-message-#{sticker.id}-user-sticker source[type='video/webm']"
           )

    assert has_element?(
             view,
             "#transcript-message-#{sticker.id}-user-sticker-id",
             "animated-sticker-id"
           )
  end

  defp create_exchange(req_id, chat_id, sender_name, request_text, response_text, opts \\ []) do
    message = %ExironClient.Message{
      req_id: req_id,
      chat_id: chat_id,
      from: %{"id" => System.unique_integer([:positive]), "first_name" => sender_name},
      datatype: Keyword.get(opts, :datatype, "text"),
      sticker_id: Keyword.get(opts, :sticker_id),
      sticker_emoji: Keyword.get(opts, :sticker_emoji),
      data: Keyword.get(opts, :data, request_text || "")
    }

    {:ok, exchange} = Conversations.create_from_message(message, "cerebras:test")

    attrs =
      if is_binary(response_text) do
        %{
          response_text: response_text,
          status: "completed",
          total_tokens: Keyword.get(opts, :total_tokens)
        }
      else
        %{status: "observed"}
      end

    {:ok, exchange} = Conversations.update_exchange(exchange, attrs)
    exchange
  end

  defp set_inserted_at(exchange, datetime) do
    exchange
    |> Ecto.Changeset.change(inserted_at: datetime, updated_at: datetime)
    |> Repo.update!()
  end

  defp webp_sticker_data, do: <<"RIFF", 0, 0, 0, 0, "WEBP", "static">>
  defp webm_sticker_data, do: <<0x1A, 0x45, 0xDF, 0xA3, "animated">>
end
