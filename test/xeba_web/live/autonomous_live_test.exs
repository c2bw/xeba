defmodule XebaWeb.AutonomousLiveTest do
  use XebaWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Xeba.Conversations

  setup %{conn: conn}, do: {:ok, conn: log_in_user(conn)}

  test "shows channel timer and message-trigger status", %{conn: conn} do
    create_messages(42, 7)

    {:ok, view, _html} = live(conn, ~p"/autonomous")

    assert has_element?(view, "#autonomous-heading")
    assert has_element?(view, "#autonomous-channel-42")
    assert has_element?(view, "#timer-countdown-42", "Scheduling")
    assert has_element?(view, "#messages-left-42", "18")
    assert has_element?(view, "#send-autonomous-now-42", "Send now")
    assert has_element?(view, "#send-autonomous-now-42[phx-disable-with='Sending…']")
    assert has_element?(view, "#toggle-autonomous-42", "Disable autonomous")
    assert has_element?(view, "#toggle-autonomous-42[phx-disable-with='Updating…']")
    assert has_element?(view, "#autonomous-settings-form-42")
    assert has_element?(view, "#context-window-42")
    assert has_element?(view, "#message-trigger-42")
    assert has_element?(view, "#save-autonomous-settings-42[phx-disable-with='Saving…']")
  end

  test "shows the Telegram chat name beside its ID", %{conn: conn} do
    create_messages(42, 1)
    assert {:ok, _chat} = Conversations.remember_chat_name(42, "Xeba Lounge")

    {:ok, view, _html} = live(conn, ~p"/autonomous")

    assert has_element?(view, "#autonomous-chat-name-42", "Xeba Lounge")
    assert has_element?(view, "#autonomous-channel-42", "chat:42")
  end

  test "disables and enables autonomous messages for a channel", %{conn: conn} do
    create_messages(77, 1)

    {:ok, view, _html} = live(conn, ~p"/autonomous")

    view
    |> element("#toggle-autonomous-77")
    |> render_click()

    refute Conversations.autonomous_enabled?(77)
    assert has_element?(view, "#timer-countdown-77", "Paused")
    assert has_element?(view, "#send-autonomous-now-77[disabled]")
    assert has_element?(view, "#toggle-autonomous-77", "Enable autonomous")

    view
    |> element("#toggle-autonomous-77")
    |> render_click()

    assert Conversations.autonomous_enabled?(77)
    refute has_element?(view, "#send-autonomous-now-77[disabled]")
    assert has_element?(view, "#toggle-autonomous-77", "Disable autonomous")
  end

  test "send now reports a disabled poller instead of a queued message", %{conn: conn} do
    create_messages(78, 1)
    {:ok, view, _} = live(conn, ~p"/autonomous")
    view |> element("#send-autonomous-now-78") |> render_click()
    assert has_element?(view, "#flash-error", "poller is disabled")
    refute has_element?(view, "#flash-info", "message queued")
  end

  test "updates context window and message trigger for a channel", %{conn: conn} do
    create_messages(88, 7)

    {:ok, view, _html} = live(conn, ~p"/autonomous")

    view
    |> form("#autonomous-settings-form-88",
      autonomous_channel_setting: %{context_window: "12", message_trigger: "10"}
    )
    |> render_submit()

    setting = Conversations.autonomous_channel_setting(88)

    assert setting.context_window == 12
    assert setting.message_trigger == 10
    assert has_element?(view, "#messages-left-88", "3")
  end

  defp create_messages(chat_id, count) do
    for number <- 1..count do
      message = %ExironClient.Message{
        req_id: "#{chat_id}-#{number}",
        chat_id: chat_id,
        datatype: "text",
        data: "message #{number}"
      }

      assert {:ok, _exchange} = Conversations.create_from_message(message, "cerebras:test")
    end
  end
end
