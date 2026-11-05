defmodule XebaWeb.ExchangeLiveTest do
  use XebaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Xeba.Conversations

  setup %{conn: conn}, do: {:ok, conn: log_in_user(conn)}

  test "renders an empty dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#exchange-count", "0")
    assert has_element?(view, "#exchanges-empty")
    assert has_element?(view, "#autonomous-settings-link")
    assert has_element?(view, "#database-text-swap-form")
    assert has_element?(view, "#database-text-swap-button[phx-disable-with='Checking…']")
    assert has_element?(view, "#exiron-connection-events-empty", "No connection events")
    assert has_element?(view, "#gateway-status", "Disabled")
    assert has_element?(view, "#token-usage-minute", "0")
    assert has_element?(view, "#token-usage-hour", "0")
    assert has_element?(view, "#token-usage-day", "0")
    refute has_element?(view, "#cerebras-tokens-remaining-minute")
    refute has_element?(view, "#cerebras-requests-remaining-day")
  end

  test "updates the rolling counters from returned token usage", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    message = %ExironClient.Message{
      req_id: "rolling-token-usage-live",
      chat_id: 123,
      datatype: "text",
      data: "Count these tokens"
    }

    assert {:ok, exchange} =
             Conversations.create_from_message(message, "cerebras:gpt-oss-120b")

    assert {:ok, _exchange} =
             Conversations.update_exchange(exchange, %{
               total_tokens: 1_234,
               tokens_used_at: DateTime.utc_now()
             })

    flush_dashboard_updates(view)
    assert has_element?(view, "#token-usage-minute", "1,234")
    assert has_element?(view, "#token-usage-hour", "1,234")
    assert has_element?(view, "#token-usage-day", "1,234")
  end

  test "streams new exchanges into the dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    message = %ExironClient.Message{
      req_id: "req-live",
      chat_id: 123,
      from: %{"id" => 7, "first_name" => "Ada", "username" => "ada"},
      datatype: "text",
      data: "Hello dashboard"
    }

    assert {:ok, exchange} = Conversations.create_from_message(message, "cerebras:gpt-oss-120b")

    flush_dashboard_updates(view)
    assert has_element?(view, "#exchanges-#{exchange.id}")
    assert has_element?(view, "#exchange-#{exchange.id}-sender", "Ada")
    assert has_element?(view, "#exchange-#{exchange.id}-request.whitespace-pre-line")
    assert has_element?(view, "#exchange-#{exchange.id}-response.whitespace-pre-line")
    assert has_element?(view, "#exchange-count", "1")
  end

  test "does not show response cards for observed exchanges", %{conn: conn} do
    {:ok, exchange} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "observed-live",
          chat_id: 123,
          from: %{"id" => 7, "first_name" => "Ada", "username" => "ada"},
          datatype: "text",
          data: "Just watching"
        },
        "cerebras:gpt-oss-120b"
      )

    {:ok, exchange} = Conversations.update_exchange(exchange, %{status: "observed"})

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#exchange-#{exchange.id}-response")
  end

  test "separates conversations by chat ID", %{conn: conn} do
    for {req_id, chat_id, text} <- [{"one", 100, "First chat"}, {"two", 200, "Second chat"}] do
      message = %ExironClient.Message{
        req_id: req_id,
        chat_id: chat_id,
        datatype: "text",
        data: text
      }

      assert {:ok, _exchange} =
               Conversations.create_from_message(message, "cerebras:gpt-oss-120b")
    end

    {:ok, view, _html} = live(conn, ~p"/chats/100")

    assert has_element?(view, "#conversation-heading", "Chat 100")
    assert has_element?(view, "#chat-100")
    assert has_element?(view, "#chat-200")
    assert has_element?(view, "#ai-context")
    assert has_element?(view, "#context-message-0", "System")
    assert has_element?(view, "#context-message-0 p.whitespace-pre-line")
    assert render(view) =~ "First chat"
    refute render(view) =~ "Second chat"
  end

  test "shows and searches an available Telegram chat name beside its ID", %{conn: conn} do
    message =
      %ExironClient.Message{
        req_id: "named-live-chat",
        chat_id: -100_321,
        datatype: "text",
        data: "Named conversation"
      }
      |> Map.put(:chat_title, "Xeba Lounge")

    assert {:ok, exchange} =
             Conversations.create_from_message(message, "cerebras:gpt-oss-120b")

    {:ok, view, _html} = live(conn, ~p"/chats/-100321")

    assert has_element?(view, "#chat--100321", "Xeba Lounge / chat:-100321")
    assert has_element?(view, "#conversation-chat-name", "Xeba Lounge")
    assert has_element?(view, "#exchange-#{exchange.id}-chat-name", "Xeba Lounge")

    view
    |> form("#conversation-filter-form", chat_filter: %{query: "lounge"})
    |> render_change()

    assert has_element?(view, "#chat--100321")
  end

  test "shows the configured context window for the selected chat", %{conn: conn} do
    message = %ExironClient.Message{
      req_id: "context-config",
      chat_id: 321,
      datatype: "text",
      data: "Configured chat"
    }

    assert {:ok, _exchange} =
             Conversations.create_from_message(message, "cerebras:gpt-oss-120b")

    assert {:ok, _setting} =
             Conversations.update_autonomous_channel_setting(321, %{
               context_window: "7",
               message_trigger: "25"
             })

    {:ok, view, _html} = live(conn, ~p"/chats/321")

    assert has_element?(view, "#context-window-summary", "7")
    assert has_element?(view, "#ai-context", "last 7 completed exchanges")
  end

  test "edits, validates, cancels, and resets the selected chat system prompt", %{conn: conn} do
    assert {:ok, _exchange} =
             Conversations.create_from_message(
               %ExironClient.Message{
                 req_id: "prompt-editor",
                 chat_id: 654,
                 datatype: "text",
                 data: "Prompt editor chat"
               },
               "test-model"
             )

    {:ok, view, _html} = live(conn, ~p"/chats/654")

    assert has_element?(view, "#system-prompt-form")
    assert has_element?(view, "#system-prompt-input", "{{bot_name}}")
    assert has_element?(view, "#system-prompt-save")
    assert has_element?(view, "#system-prompt-cancel")

    view
    |> form("#system-prompt-form", system_prompt: %{prompt: "Custom for {{bot_name}}"})
    |> render_submit()

    assert Conversations.system_prompt_template(654) == "Custom for {{bot_name}}"
    assert has_element?(view, "#context-message-0", "Custom for xeba")

    view
    |> form("#system-prompt-form", system_prompt: %{prompt: "   "})
    |> render_change()

    assert has_element?(view, "#system-prompt-error", "System prompt cannot be blank.")
    assert has_element?(view, "#system-prompt-save[disabled]")

    view
    |> form("#system-prompt-form", system_prompt: %{prompt: "Unsaved"})
    |> render_change()

    view |> element("#system-prompt-cancel") |> render_click()
    assert has_element?(view, "#system-prompt-input", "Custom for {{bot_name}}")

    assert has_element?(
             view,
             "#system-prompt-reset[data-confirm='Restore the default system prompt for this chat?']"
           )

    view |> element("#system-prompt-reset") |> render_click()
    assert Conversations.system_prompt_template(654) == Xeba.Telegram.Prompt.default_template()
    assert has_element?(view, "#context-message-0", "You are a companion named xeba")
  end

  test "shows sticker requests in the dashboard", %{conn: conn} do
    {:ok, exchange} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "sticker-live",
          chat_id: 123,
          datatype: "file",
          sticker_id: "telegram-sticker-id",
          sticker_emoji: "party",
          data: webp_sticker_data()
        },
        "cerebras:gpt-oss-120b"
      )

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#exchanges-#{exchange.id}", "[sticker party]")

    assert has_element?(
             view,
             "#exchange-#{exchange.id}-sticker[src='/chats/123/exchanges/#{exchange.id}/media'][loading='lazy']"
           )

    assert has_element?(view, "#exchange-#{exchange.id}-sticker-id", "telegram-sticker-id")
  end

  test "shows animated sticker requests in the dashboard", %{conn: conn} do
    {:ok, exchange} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "animated-sticker-live",
          chat_id: 123,
          datatype: "file",
          sticker_id: "animated-sticker-id",
          sticker_emoji: "dance",
          data: webm_sticker_data()
        },
        "cerebras:gpt-oss-120b"
      )

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#exchange-#{exchange.id}-sticker source[type='video/webm']")
    assert has_element?(view, "#exchange-#{exchange.id}-sticker-id", "animated-sticker-id")
  end

  test "swaps database text from the dashboard", %{conn: conn} do
    {:ok, exchange} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "swap-live",
          chat_id: 123,
          from: %{"id" => 7, "first_name" => "AndreBot", "username" => "andrebot"},
          datatype: "text",
          data: "hello ANDREBOT"
        },
        "cerebras:gpt-oss-120b"
      )

    {:ok, exchange} = Conversations.update_exchange(exchange, %{status: "observed"})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#exchange-#{exchange.id}-sender", "AndreBot")

    view
    |> form("#database-text-swap-form", replace: %{from: "andrebot", to: "ilariabot"})
    |> render_submit()

    assert has_element?(view, "#database-text-swap-preview", "1 row will change")
    assert has_element?(view, "#exchange-#{exchange.id}-sender", "AndreBot")

    view
    |> element("#database-text-swap-confirm")
    |> render_click()

    assert has_element?(view, "#exchange-#{exchange.id}-sender", "ilariabot")
    assert render(view) =~ "hello ilariabot"
    refute render(view) =~ "hello ANDREBOT"
    assert has_element?(view, "#database-text-swap-undo")

    view
    |> element("#database-text-swap-undo-button")
    |> render_click()

    assert has_element?(view, "#exchange-#{exchange.id}-sender", "AndreBot")
    assert render(view) =~ "hello ANDREBOT"
    refute has_element?(view, "#database-text-swap-undo")
  end

  test "filters the compact conversation picker by chat ID", %{conn: conn} do
    for chat_id <- [120, 987] do
      assert {:ok, _exchange} =
               Conversations.create_from_message(
                 %ExironClient.Message{
                   req_id: "filter-chat-#{chat_id}",
                   chat_id: chat_id,
                   datatype: "text",
                   data: "chat #{chat_id}"
                 },
                 "cerebras:test"
               )
    end

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#conversation-filter-form", chat_filter: %{query: "987"})
    |> render_change()

    assert has_element?(view, "#chat-987")
    refute has_element?(view, "#chat-120")
  end

  defp webp_sticker_data, do: <<"RIFF", 0, 0, 0, 0, "WEBP", "static">>
  defp webm_sticker_data, do: <<0x1A, 0x45, 0xDF, 0xA3, "animated">>
end
