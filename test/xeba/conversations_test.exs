defmodule Xeba.ConversationsTest do
  use Xeba.DataCase

  alias Xeba.Conversations
  alias Xeba.Conversations.{ChatSticker, Exchange}
  alias Xeba.Repo

  test "returns the latest twenty completed exchanges in chronological order" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for number <- 1..22 do
      %Exchange{}
      |> Exchange.changeset(%{
        req_id: "request-#{number}",
        chat_id: 42,
        datatype: "text",
        request_text: "question #{number}",
        response_text: "answer #{number}",
        status: "completed",
        completed_at: DateTime.add(now, number, :second)
      })
      |> Repo.insert!()
    end

    history = Conversations.recent_history(42, 20)

    assert length(history) == 20
    assert hd(history).request_text == "question 3"
    assert List.last(history).request_text == "question 22"
  end

  test "enforces unique Exiron request IDs" do
    message = %ExironClient.Message{req_id: "same", datatype: "text", data: "hello"}

    assert {:ok, _exchange} = Conversations.create_from_message(message, "cerebras:test")
    assert {:error, changeset} = Conversations.create_from_message(message, "cerebras:test")
    assert "has already been taken" in errors_on(changeset).req_id
  end

  test "uses, updates, and resets a system prompt independently per chat" do
    assert Conversations.system_prompt_template(42) == Xeba.Telegram.Prompt.default_template()
    assert Conversations.system_prompt_template(99) == Xeba.Telegram.Prompt.default_template()

    assert {:ok, setting} =
             Conversations.update_autonomous_channel_setting(42, %{
               context_window: 7,
               message_trigger: 11
             })

    assert {:ok, updated} = Conversations.update_system_prompt(42, "Custom {{bot_name}}")
    assert updated.system_prompt == "Custom {{bot_name}}"
    assert updated.context_window == setting.context_window
    assert updated.message_trigger == setting.message_trigger
    assert Conversations.system_prompt_template(42) == "Custom {{bot_name}}"
    assert Conversations.system_prompt_template(99) == Xeba.Telegram.Prompt.default_template()

    assert {:error, :blank_system_prompt} = Conversations.update_system_prompt(42, "   ")
    assert {:ok, reset} = Conversations.reset_system_prompt(42)
    assert is_nil(reset.system_prompt)
    assert reset.context_window == 7
    assert reset.message_trigger == 11
    assert Conversations.system_prompt_template(42) == Xeba.Telegram.Prompt.default_template()
  end

  test "sums returned token usage over rolling minute, hour, and day windows" do
    now = ~U[2026-07-14 18:30:00Z]

    insert_token_usage!(100, DateTime.add(now, -15, :second), "minute")
    insert_token_usage!(200, DateTime.add(now, -30, :minute), "hour")
    insert_token_usage!(300, DateTime.add(now, -12, :hour), "day")
    insert_token_usage!(400, DateTime.add(now, -2, :day), "expired")

    assert Conversations.rolling_token_usage(now) == %{
             minute: 100,
             hour: 300,
             day: 600
           }
  end

  test "stores listen messages without request IDs and includes them in chat history" do
    message = %ExironClient.Message{
      msgtype: "listen",
      req_id: nil,
      message_id: 77,
      service_id: 9,
      chat_id: 42,
      from: %{
        "id" => 123,
        "is_bot" => false,
        "first_name" => "Ada",
        "last_name" => "Lovelace",
        "username" => "ada",
        "language_code" => "en"
      },
      datatype: "text",
      data: "ordinary chat message"
    }

    assert {:ok, exchange} = Conversations.create_from_message(message, "cerebras:test")
    assert {:ok, exchange} = Conversations.update_exchange(exchange, %{status: "observed"})

    assert exchange.req_id == nil
    assert exchange.msgtype == "listen"
    assert exchange.sender_id == 123
    assert exchange.sender_is_bot == false
    assert exchange.sender_first_name == "Ada"
    assert exchange.sender_last_name == "Lovelace"
    assert exchange.sender_username == "ada"
    assert exchange.sender_language_code == "en"
    assert [history_message] = Conversations.recent_history(42)
    assert history_message.request_text == "ordinary chat message"
    assert history_message.response_text == nil
  end

  test "remembers available Telegram chat names" do
    message =
      %ExironClient.Message{
        req_id: "named-chat",
        chat_id: -100_123,
        datatype: "text",
        data: "hello group"
      }
      |> Map.put(:chat_title, "Xeba Lounge")

    assert {:ok, _exchange} = Conversations.create_from_message(message, "cerebras:test")

    assert Conversations.chat_name(-100_123) == "Xeba Lounge"

    assert [%{chat_id: -100_123, chat_name: "Xeba Lounge"}] =
             Conversations.list_chats()

    message = %ExironClient.Message{
      req_id: "private-chat",
      chat_id: 123,
      from: %{"id" => 123, "first_name" => "Ada", "last_name" => "Lovelace"},
      datatype: "text",
      data: "hello"
    }

    assert {:ok, _exchange} = Conversations.create_from_message(message, "cerebras:test")
    assert Conversations.chat_name(123) == "Ada Lovelace"

    assert :ok =
             Conversations.remember_chat_names_from_status(%{
               "membership_events" => [
                 %{"chat_id" => -456, "chat_title" => "Current group"},
                 %{"chat_id" => -456, "chat_title" => "Older group"}
               ]
             })

    assert Conversations.chat_name(-456) == "Current group"
  end

  test "stores sticker metadata and banks stickers per chat" do
    message = %ExironClient.Message{
      req_id: "sticker-request",
      chat_id: 42,
      datatype: "file",
      sticker_id: "telegram-sticker-id",
      sticker_emoji: "party",
      emoji_list: ["party", "celebrate"],
      data: webp_sticker_data()
    }

    assert {:ok, exchange} = Conversations.create_from_message(message, "cerebras:test")

    assert exchange.sticker_id == "telegram-sticker-id"
    assert exchange.sticker_emoji == "party"
    assert exchange.sticker_data == webp_sticker_data()

    assert [%ChatSticker{} = sticker] = Conversations.list_chat_stickers(42)
    assert sticker.chat_id == 42
    assert sticker.sticker_id == "telegram-sticker-id"
    assert sticker.emoji == "party"
    assert sticker.emoji_list == ["party", "celebrate"]
    assert sticker.data == webp_sticker_data()
    assert [^sticker] = Conversations.list_chat_stickers_for_emoji(42, "celebrate")

    updated_message = %{
      message
      | req_id: "sticker-request-2",
        sticker_emoji: "spark",
        emoji_list: ["spark", "shine"],
        data: webm_sticker_data()
    }

    assert {:ok, _exchange} = Conversations.create_from_message(updated_message, "cerebras:test")

    assert [%ChatSticker{} = updated_sticker] = Conversations.list_chat_stickers(42)
    assert updated_sticker.sticker_id == "telegram-sticker-id"
    assert updated_sticker.emoji == "spark"
    assert updated_sticker.emoji_list == ["spark", "shine"]
    assert updated_sticker.data == webm_sticker_data()
    assert [^updated_sticker] = Conversations.list_chat_stickers_for_emoji(42, "shine")
  end

  test "includes observed sticker messages in chat history" do
    message = %ExironClient.Message{
      req_id: "history-sticker",
      chat_id: 42,
      datatype: "file",
      sticker_id: "history-sticker-id",
      sticker_emoji: "laugh",
      emoji_list: ["laugh"],
      data: webp_sticker_data()
    }

    assert {:ok, exchange} = Conversations.create_from_message(message, "cerebras:test")
    assert {:ok, _exchange} = Conversations.update_exchange(exchange, %{status: "observed"})

    assert [history_message] = Conversations.recent_history(42)
    assert history_message.sticker_emoji == "laugh"
    assert history_message.request_text == nil
  end

  test "stores per-channel autonomous settings" do
    assert Conversations.autonomous_enabled?(42)

    assert {:ok, setting} = Conversations.set_autonomous_enabled(42, false)
    refute setting.enabled
    refute Conversations.autonomous_enabled?(42)

    assert {:ok, setting} = Conversations.set_autonomous_enabled(42, true)
    assert setting.enabled
    assert Conversations.autonomous_enabled?(42)

    assert {:ok, setting} =
             Conversations.update_autonomous_channel_setting(42, %{
               context_window: "8",
               message_trigger: "12"
             })

    assert setting.context_window == 8
    assert setting.message_trigger == 12
    assert Conversations.autonomous_channel_setting(42).context_window == 8
    assert Conversations.autonomous_channel_setting(42).message_trigger == 12
  end

  test "replaces display text without modifying protocol identifiers" do
    exchange =
      %Exchange{}
      |> Exchange.changeset(%{
        req_id: "AndreBot-request",
        chat_id: 42,
        sender_first_name: "ANDREBOT",
        sender_username: "team_AndreBot",
        datatype: "text",
        request_text: "hello andrebot and AndreBot",
        response_text: "ANDREBOT says hi",
        model: "cerebras:AndreBot",
        status: "completed",
        error: nil
      })
      |> Repo.insert!()

    assert {:ok, 1} = Conversations.replace_database_text("andrebot", "ilariabot")

    updated = Repo.get!(Exchange, exchange.id)
    assert updated.req_id == "AndreBot-request"
    assert updated.sender_first_name == "ilariabot"
    assert updated.sender_username == "team_ilariabot"
    assert updated.request_text == "hello ilariabot and ilariabot"
    assert updated.response_text == "ilariabot says hi"
    assert updated.model == "cerebras:AndreBot"
  end

  test "previews and exactly undoes a database text replacement" do
    exchange =
      %Exchange{}
      |> Exchange.changeset(%{
        req_id: "Undo-AndreBot",
        chat_id: 99,
        sender_first_name: "ANDREBOT",
        datatype: "text",
        request_text: "AndreBot and andrebot",
        response_text: "Keep the original CASE",
        model: "cerebras:test",
        status: "completed"
      })
      |> Repo.insert!()

    assert {:ok, 1} = Conversations.preview_database_text_replacement(" andrebot ")

    assert {:ok, %{updated_rows: 1, operation: operation}} =
             Conversations.replace_database_text_with_undo("andrebot", "xeba")

    assert operation.affected_rows == 1
    assert Conversations.latest_undoable_database_text_replacement().id == operation.id

    updated = Repo.get!(Exchange, exchange.id)
    assert updated.req_id == "Undo-AndreBot"
    assert updated.sender_first_name == "xeba"
    assert updated.request_text == "xeba and xeba"

    assert {:ok, %{restored_rows: 1}} =
             Conversations.undo_database_text_replacement(operation)

    restored = Repo.get!(Exchange, exchange.id)
    assert restored.req_id == "Undo-AndreBot"
    assert restored.sender_first_name == "ANDREBOT"
    assert restored.request_text == "AndreBot and andrebot"
    assert restored.response_text == "Keep the original CASE"
    assert Conversations.latest_undoable_database_text_replacement() == nil
    assert {:error, :already_undone} = Conversations.undo_database_text_replacement(operation)
  end

  test "does not replace text with a blank source" do
    assert {:error, :blank_source} = Conversations.replace_database_text(" ", "ilariabot")
    assert {:error, :blank_source} = Conversations.preview_database_text_replacement(" ")
  end

  test "text replacement cannot change protocol state or delivery identifiers" do
    exchange =
      Repo.insert!(%Exchange{
        req_id: "completed",
        msgtype: "request",
        datatype: "text",
        status: "completed",
        model: "completed",
        sticker_id: "completed",
        request_text: "hello"
      })

    assert {:ok, 0} = Conversations.preview_database_text_replacement("completed")
    assert {:ok, 0} = Conversations.replace_database_text("completed", "renamed")
    assert Repo.get!(Exchange, exchange.id) == exchange
  end

  test "a pending match blocks the entire replacement, including previously previewed edits" do
    completed =
      Repo.insert!(%Exchange{
        req_id: "replace-complete",
        datatype: "text",
        status: "completed",
        request_text: "old name"
      })

    assert {:ok, 1} = Conversations.preview_database_text_replacement("old name")

    pending =
      Repo.insert!(%Exchange{
        req_id: "replace-pending",
        datatype: "text",
        status: "pending",
        request_text: "old name"
      })

    assert {:error, :delivery_in_progress} =
             Conversations.replace_database_text("old name", "new name")

    assert Repo.get!(Exchange, completed.id).request_text == "old name"
    assert Repo.get!(Exchange, pending.id).request_text == "old name"
    assert Repo.aggregate(Conversations.DatabaseTextReplacement, :count) == 0
  end

  test "undo preserves unrelated fields updated after the replacement" do
    exchange =
      Repo.insert!(%Exchange{
        req_id: "safe-undo",
        datatype: "text",
        status: "completed",
        request_text: "old name"
      })

    {:ok, %{operation: operation}} =
      Conversations.replace_database_text_with_undo("old name", "new name")

    {:ok, _} =
      Conversations.update_exchange(exchange, %{response_text: "New reply", status: "completed"})

    assert {:ok, _} = Conversations.undo_database_text_replacement(operation)
    restored = Repo.get!(Exchange, exchange.id)
    assert restored.request_text == "old name"
    assert restored.response_text == "New reply"
    assert restored.status == "completed"
  end

  test "undo refuses to overwrite a later edit to a field it changed" do
    exchange =
      Repo.insert!(%Exchange{
        req_id: "conflict-undo",
        datatype: "text",
        status: "completed",
        request_text: "old name"
      })

    {:ok, %{operation: operation}} =
      Conversations.replace_database_text_with_undo("old name", "new name")

    {:ok, _} = Conversations.update_exchange(exchange, %{request_text: "A later edit"})

    assert {:error, :restore_conflict} = Conversations.undo_database_text_replacement(operation)
    assert Repo.get!(Exchange, exchange.id).request_text == "A later edit"
    assert Repo.get!(Conversations.DatabaseTextReplacement, operation.id).undone_at == nil
  end

  test "legacy undo snapshots are rejected without changing stored text" do
    exchange =
      Repo.insert!(%Exchange{req_id: "legacy-undo", datatype: "text", request_text: "new name"})

    operation =
      Repo.insert!(%Conversations.DatabaseTextReplacement{
        source_text: "old name",
        replacement_text: "new name",
        affected_rows: 1,
        snapshot: %{"rows" => [%{"id" => exchange.id, "request_text" => "old name"}]}
      })

    assert {:error, :legacy_snapshot} = Conversations.undo_database_text_replacement(operation)
    assert Repo.get!(Exchange, exchange.id).request_text == "new name"
  end

  defp webp_sticker_data, do: <<"RIFF", 0, 0, 0, 0, "WEBP", "static">>
  defp webm_sticker_data, do: <<0x1A, 0x45, 0xDF, 0xA3, "animated">>

  defp insert_token_usage!(tokens, used_at, req_id) do
    %Exchange{}
    |> Exchange.changeset(%{
      req_id: "token-usage-#{req_id}",
      datatype: "text",
      status: "completed",
      total_tokens: tokens,
      tokens_used_at: used_at
    })
    |> Repo.insert!()
  end
end
