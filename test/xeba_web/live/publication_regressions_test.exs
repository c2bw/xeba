defmodule XebaWeb.PublicationRegressionsTest do
  use XebaWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Xeba.Conversations

  setup %{conn: conn} do
    {:ok, exchange} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "publication-regression",
          chat_id: 42,
          datatype: "text",
          data: "Old text"
        },
        "test"
      )

    {:ok, _} = Conversations.update_exchange(exchange, %{status: "observed"})
    {:ok, conn: log_in_user(conn)}
  end

  test "settings and replacement broadcasts keep other pages connected", %{conn: conn} do
    {:ok, transcript, _} = live(conn, ~p"/chats/42/transcript")
    {:ok, autonomous, _} = live(conn, ~p"/autonomous")

    {:ok, _} = Conversations.update_autonomous_channel_setting(42, %{message_trigger: 10})
    assert has_element?(transcript, "#transcript-message-count")
    assert has_element?(autonomous, "#messages-left-42", "9")

    {:ok, 1} = Conversations.replace_database_text("Old", "New")
    assert has_element?(autonomous, "#autonomous-channel-42")
    assert has_element?(transcript, "#transcript-message-count")
  end

  test "toggle updates another autonomous page", %{conn: conn} do
    {:ok, first, _} = live(conn, ~p"/autonomous")
    {:ok, second, _} = live(conn, ~p"/autonomous")
    first |> element("#toggle-autonomous-42") |> render_click()
    assert has_element?(second, "#send-autonomous-now-42[disabled]")
  end

  test "ticks do not query history or settings", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/autonomous")
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:xeba, :repo, :query],
        fn _, _, meta, _ ->
          send(test_pid, {:sql, meta.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(view.pid, :tick)
    _ = :sys.get_state(view.pid)
    queries = collect_queries([])
    assert Enum.all?(queries, &String.contains?(&1, ~s(FROM "sessions")))
    assert has_element?(view, "#timer-countdown-42")
  end

  test "channel refresh batches counts and settings across chats", %{conn: conn} do
    for id <- 43..45 do
      {:ok, _} =
        Conversations.create_from_message(
          %ExironClient.Message{
            req_id: "batch-#{id}",
            chat_id: id,
            datatype: "text",
            data: "hello"
          },
          "test"
        )
    end

    {:ok, view, _} = live(conn, ~p"/autonomous")
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:xeba, :repo, :query],
        fn _, _, meta, _ ->
          send(owner, {:sql, meta.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(view.pid, {:chat_updated, %{chat_id: 42}})
    _ = :sys.get_state(view.pid)
    queries = collect_queries([]) |> Enum.reject(&String.contains?(&1, ~s(FROM "sessions")))
    assert length(queries) == 3
    for id <- 42..45, do: assert(has_element?(view, "#messages-left-#{id}", "24"))
  end

  test "settings cannot reassign their channel through submitted fields", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/autonomous")

    render_click(view, "save-settings", %{
      "chat-id" => "42",
      "autonomous_channel_setting" => %{
        "chat_id" => "999999999999999999999999",
        "message_trigger" => "10"
      }
    })

    assert has_element?(view, "#messages-left-42", "9")
    assert Conversations.autonomous_channel_setting(42).message_trigger == 10
  end

  test "invalid and unknown channel event IDs leave the page usable", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/autonomous")

    for id <- ["bad", "999999999999999999999999", "404", nil],
        event <- [
          "toggle-autonomous",
          "send-autonomous-now",
          "validate-settings",
          "save-settings"
        ] do
      render_click(view, event, %{
        "chat-id" => id,
        "autonomous_channel_setting" => %{"message_trigger" => "1"}
      })

      assert has_element?(view, "#flash-error", "chat is not available")
    end

    assert Conversations.autonomous_enabled?(42)
    assert has_element?(view, "#autonomous-channel-42")
    assert Xeba.Repo.aggregate(Xeba.Conversations.AutonomousChannelSetting, :count) == 0
  end

  test "oversized chat URLs redirect without a database encoding error", %{conn: conn} do
    for path <- [
          "/chats/99999999999999999999999",
          "/chats/99999999999999999999999/transcript",
          "/chats/99999999999999999999999/stickers"
        ] do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, path)
    end
  end

  defp collect_queries(acc) do
    receive do
      {:sql, sql} -> collect_queries([sql | acc])
    after
      0 -> acc
    end
  end
end
