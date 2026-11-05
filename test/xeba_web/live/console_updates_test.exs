defmodule XebaWeb.ConsoleUpdatesTest do
  use XebaWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Xeba.Conversations

  setup %{conn: conn} do
    {:ok, _} = Conversations.update_system_prompt(42, "Stored original")
    {:ok, conn: log_in_user(conn)}
  end

  test "settings and remote prompt changes preserve dirty drafts and validation errors", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/chats/42")
    view |> form("#system-prompt-form", system_prompt: %{prompt: "My draft"}) |> render_change()
    {:ok, _} = Conversations.update_autonomous_channel_setting(42, %{context_window: 7})
    assert has_element?(view, "#system-prompt-input", "My draft")
    assert has_element?(view, "#context-window-summary", "7")

    {:ok, _} = Conversations.update_system_prompt(42, "Changed in another tab")
    assert has_element?(view, "#system-prompt-input", "My draft")
    view |> element("#system-prompt-cancel") |> render_click()
    assert has_element?(view, "#system-prompt-input", "Changed in another tab")

    view |> form("#system-prompt-form", system_prompt: %{prompt: "  "}) |> render_submit()
    {:ok, _} = Conversations.update_autonomous_channel_setting(42, %{message_trigger: 10})
    assert has_element?(view, "#system-prompt-error", "cannot be blank")
    assert has_element?(view, "#system-prompt-save[disabled]")
  end

  test "saving clears dirty state, while clean editors follow remote updates", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/chats/42")

    view
    |> form("#system-prompt-form", system_prompt: %{prompt: "Saved draft"})
    |> render_submit()

    {:ok, _} = Conversations.update_system_prompt(42, "Remote after save")
    assert has_element?(view, "#system-prompt-input", "Remote after save")

    view
    |> form("#system-prompt-form", system_prompt: %{prompt: "Matched elsewhere"})
    |> render_change()

    {:ok, _} = Conversations.update_system_prompt(42, "Matched elsewhere")
    assert has_element?(view, "#system-prompt-input", "Matched elsewhere")
    {:ok, _} = Conversations.update_system_prompt(42, "Remote after match")
    assert has_element?(view, "#system-prompt-input", "Remote after match")
  end

  test "a burst refreshes the dashboard once and displays the latest saved state", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    observe_queries(view)
    :ok = :sys.suspend(view.pid)

    try do
      {:ok, exchange} =
        Conversations.create_from_message(
          %ExironClient.Message{
            req_id: "refresh-burst",
            chat_id: 42,
            datatype: "text",
            data: "Question"
          },
          "test"
        )

      {:ok, exchange} =
        Conversations.update_exchange(exchange, %{
          status: "completed",
          response_text: "Final answer",
          total_tokens: 123,
          tokens_used_at: DateTime.utc_now()
        })

      for _ <- 1..10, do: send(view.pid, {:exchange_updated, exchange})
    after
      :sys.resume(view.pid)
    end

    flush_dashboard_updates(view)
    assert has_element?(view, "#exchange-count", "1")
    assert has_element?(view, "#token-usage-minute", "123")
    [exchange] = Conversations.list_exchanges_for_chat(42)
    assert has_element?(view, "#exchange-#{exchange.id}-response", "Final answer")
    queries = collect_queries([])
    assert length(queries) == 3

    {:ok, _} = Conversations.update_exchange(exchange, %{response_text: "Later answer"})
    flush_dashboard_updates(view)
    assert has_element?(view, "#exchange-#{exchange.id}-response", "Later answer")
    assert length(collect_queries([])) == 3
  end

  test "updates from another chat skip the current exchange list and context", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/chats/42")
    observe_queries(view)
    :ok = :sys.suspend(view.pid)

    try do
      for _ <- 1..10, do: send(view.pid, {:exchange_updated, %{chat_id: 99}})
    after
      :sys.resume(view.pid)
    end

    flush_dashboard_updates(view)
    queries = collect_queries([])
    assert length(queries) == 2
    refute Enum.any?(queries, &String.contains?(&1, "substring("))
    assert has_element?(view, "#system-prompt-input", "Stored original")
  end

  defp observe_queries(view) do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:xeba, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == view.pid and not String.contains?(metadata.query, ~s(FROM "sessions")),
            do: send(owner, {:dashboard_query, metadata.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp collect_queries(acc) do
    receive do
      {:dashboard_query, sql} -> collect_queries([sql | acc])
    after
      0 -> acc
    end
  end
end
