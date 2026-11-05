defmodule Xeba.Telegram.ReplyTest do
  use Xeba.DataCase
  import Xeba.Telegram.PollerHelpers
  alias Xeba.Conversations
  alias Xeba.Conversations.OutgoingMessage
  alias Xeba.Telegram.{Autonomous, Delivery}

  setup do
    {:ok, _} = Conversations.set_autonomous_enabled(910, false)
    {:ok, _} = Conversations.set_autonomous_enabled(911, false)
    ids = start_supervised!({Agent, fn -> 900 end})

    state = %{
      enabled: true,
      client: %{owner: self(), ids: ids},
      exiron: Xeba.Telegram.PollerReceiptExironFake,
      llm: Xeba.Telegram.PollerCaptionLLMFake,
      llm_options: [test_pid: self()],
      model: "test-model",
      bot_name: "xeba",
      autonomous_timers: %{},
      sticker_reply_delay_ms: 0
    }

    %{state: state, queue: start_message_queue()}
  end

  test "a reply to either split message triggers an answer without a name and survives a new worker",
       ctx do
    first = %{message(1, nil, "/ai hello") | msgtype: "request", req_id: "first"}
    assert :ok = run_prepared_message(first, ctx.state, ctx.queue)
    assert_receive {:llm_context, _}
    assert Repo.aggregate(OutgoingMessage, :count) == 2

    # Another queue/harness has no access to the previous worker's memory.
    queue = start_message_queue()
    reply = message(2, 902, "why is that?")
    assert :ok = run_prepared_message(reply, ctx.state, queue)
    assert_receive {:llm_context, context}

    assert last_user_text(context) =~
             "[Replying to a previous message from xeba]\nCaption received"

    assert last_user_text(context) =~ "[Current message]\nwhy is that?"
    assert_receive {:push_text, 910, "Caption received", opts}
    assert is_binary(opts[:idempotency_key])
    assert Conversations.get_by_message(reply).status == "completed"

    assert :ok = run_prepared_message(reply, ctx.state, queue)
    refute_received {:llm_context, _}
  end

  test "replies to autonomous messages and captioned files are recognized outside recent history",
       ctx do
    {:ok, _} = Conversations.set_autonomous_enabled(910, true)

    assert %{status: "completed"} =
             Autonomous.generate(910, "start", ctx.state, schedule_follow_up?: false)

    assert_receive {:llm_context, _}
    {:ok, _} = Conversations.set_autonomous_enabled(910, false)
    {:ok, _} = Conversations.update_autonomous_channel_setting(910, %{context_window: 1})
    noise = message(3, nil, "unrelated recent message")
    assert :ok = run_prepared_message(noise, ctx.state, ctx.queue)

    reply = %{
      message(4, 901, "binary bytes")
      | datatype: "file",
        data: <<255, 0>>,
        caption: "why?"
    }

    assert :ok = run_prepared_message(reply, ctx.state, ctx.queue)
    assert_receive {:llm_context, context}
    assert last_user_text(context) =~ "Caption received"
    assert last_user_text(context) =~ "[Current message]\nwhy?"
    assert Conversations.get_by_message(reply).status == "completed"
  end

  test "replies to sent stickers are recognized and identify the sticker in context", ctx do
    {:ok, exchange} = Conversations.create_autonomous(910, "test-model", %{})

    {:ok, exchange} =
      Conversations.update_exchange(exchange, %{
        response_text: "Nice",
        delivery_state: %{"plan" => %{"text" => "Nice", "emoji" => "🔥"}, "text_sent" => true}
      })

    {:ok, _} =
      Conversations.checkpoint_delivery(exchange, "sticker_sent", %{
        "receipts" => [%{"service_id" => 222, "chat_id" => 910, "message_ids" => [950]}]
      })

    reply = message(5, 950, "same feeling")
    assert :ok = run_prepared_message(reply, ctx.state, ctx.queue)
    assert_receive {:llm_context, context}
    assert last_user_text(context) =~ "[sticker 🔥]"
  end

  test "unknown IDs, other chats/services/topics, and bot replies do not trigger responses",
       ctx do
    seed_receipt(nil)

    for {id, changes} <- [
          {10, %{reply_to_message_id: 999}},
          {11, %{chat_id: 911}},
          {12, %{service_id: 333}},
          {13, %{message_thread_id: 7}},
          {14, %{from: %{"is_bot" => true}}}
        ] do
      reply = struct!(message(id, 901, "ordinary reply"), changes)
      assert :ok = run_prepared_message(reply, ctx.state, ctx.queue)
      assert Conversations.get_by_message(reply).status == "observed"
    end

    refute_received {:llm_context, _}
  end

  test "topic replies stay in their topic and do not inherit another topic's receipt", ctx do
    seed_receipt(7)
    Agent.update(ctx.state.client.ids, fn _ -> 902 end)
    reply = %{message(15, 901, "why?") | message_thread_id: 7}
    assert :ok = run_prepared_message(reply, ctx.state, ctx.queue)
    assert_receive {:llm_context, _}
    assert_receive {:push_text, 910, _, opts}
    assert opts[:message_thread_id] == 7
    assert Conversations.get_by_message(reply).message_thread_id == 7
    assert Conversations.reply_target(%{message(16, 903, "next") | message_thread_id: 7})
  end

  test "delivery retry retains receipts without sending completed parts again", ctx do
    {:ok, exchange} = Conversations.create_autonomous(910, "test-model", %{})
    assert {:ok, saved} = Delivery.deliver(exchange, %{chat_id: 910}, "hello", ctx.state)
    assert_receive {:push_text, 910, "hello", _}
    assert saved.delivery_state["text_sent"]
    assert Repo.aggregate(OutgoingMessage, :count) == 2
    assert {:ok, _} = Delivery.deliver(saved, %{chat_id: 910}, "hello", ctx.state)
    refute_received {:push_text, _, _, _}
    assert Repo.aggregate(OutgoingMessage, :count) == 2
  end

  test "old or malformed receipts never mistake another message for Xeba's output" do
    {:ok, exchange} = Conversations.create_autonomous(910, "test-model", %{})
    {:ok, _} = Conversations.checkpoint_delivery(exchange, "text_sent", %{ok: true})

    {:ok, _} =
      Conversations.checkpoint_delivery(exchange, "text_sent", %{
        receipts: [
          %{service_id: 222, chat_id: 911, message_ids: [901]},
          %{service_id: 222, chat_id: 910, message_ids: [nil, -1, "902"]}
        ]
      })

    refute Conversations.reply_target(message(17, 901, "why?"))
    assert Repo.aggregate(OutgoingMessage, :count) == 0
  end

  defp seed_receipt(thread) do
    {:ok, exchange} = Conversations.create_autonomous(910, "test-model", %{})
    {:ok, exchange} = Conversations.update_exchange(exchange, %{response_text: "Earlier answer"})

    Conversations.checkpoint_delivery(exchange, "text_sent", %{
      receipts: [%{service_id: 222, chat_id: 910, message_thread_id: thread, message_ids: [901]}]
    })
  end

  defp message(id, reply_to, text) do
    %ExironClient.Message{
      msgtype: "message",
      service_id: 222,
      chat_id: 910,
      message_id: id,
      reply_to_message_id: reply_to,
      datatype: "text",
      data: text
    }
  end

  defp last_user_text(context) do
    context.messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
    |> Map.fetch!(:content)
    |> Enum.map_join("", & &1.text)
  end
end
