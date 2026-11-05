defmodule Xeba.Telegram.CaptionTest do
  use Xeba.DataCase

  import Xeba.Telegram.PollerHelpers

  alias Xeba.Conversations
  alias Xeba.Telegram.Prompt

  setup do
    {:ok, _} = Conversations.set_autonomous_enabled(910, false)

    state = %{
      enabled: true,
      client: %{owner: self()},
      exiron: Xeba.Telegram.PollerExironFake,
      llm: Xeba.Telegram.PollerCaptionLLMFake,
      llm_options: [test_pid: self()],
      model: "test-model",
      bot_name: "xeba",
      autonomous_timers: %{},
      sticker_reply_delay_ms: 0
    }

    {:ok, state: state, queue: start_message_queue()}
  end

  test "observed photo and file captions appear in history and future AI context", ctx do
    for {datatype, id} <- [{"image", 1}, {"file", 2}] do
      message = media(datatype, id, "#{datatype} caption")
      assert :ok = run_prepared_message(message, ctx.state, ctx.queue)
      assert %{status: "observed", request_text: text} = Conversations.get_by_message(message)
      assert text == "#{datatype} caption"
    end

    refute_received {:llm_context, _}

    history = Prompt.preview(Conversations.recent_history(910), "xeba")
    assert Enum.any?(history, &(&1.role == :user and &1.content =~ "image caption"))
    assert Enum.any?(history, &(&1.role == :user and &1.content =~ "file caption"))

    request = %ExironClient.Message{
      msgtype: "request",
      req_id: "later",
      chat_id: 910,
      datatype: "text",
      data: "/ai hello"
    }

    assert :ok = run_prepared_message(request, ctx.state, ctx.queue)
    assert_receive {:llm_context, context}
    assert context_text(context) =~ "image caption"
    assert context_text(context) =~ "file caption"
  end

  test "a bot mention in a photo caption triggers a reply using caption text", ctx do
    message = media("image", 3, "@xeba what a dinner")
    assert :ok = run_prepared_message(message, ctx.state, ctx.queue)
    assert_receive {:llm_context, context}
    assert context_text(context) =~ "what a dinner"
    refute context_text(context) =~ "@xeba"
    assert_receive {:push_text, 910, "Caption received"}

    assert %{status: "completed", request_text: "@xeba what a dinner"} =
             Conversations.get_by_message(message)
  end

  test "routed file captions are normalized and replied to, including pending replay", ctx do
    message = %{
      media("file", 4, "/ai dinner thoughts")
      | msgtype: "request",
        req_id: "file-request"
    }

    {:ok, _} = Conversations.create_from_message(message, "test-model")

    assert :ok = run_prepared_message(message, ctx.state, ctx.queue)
    assert_receive {:llm_context, context}
    assert context_text(context) =~ "dinner thoughts"
    refute context_text(context) =~ "/ai"
    assert_receive {:reply_text, ^message, "Caption received"}
    assert Conversations.get_by_message(message).status == "completed"

    assert :ok = run_prepared_message(message, ctx.state, ctx.queue)
    refute_received {:llm_context, _}
  end

  test "mentions in album member captions trigger a reply with all captions", ctx do
    message = %{
      media("album", 5, nil)
      | media_items: [
          %ExironClient.MediaItem{datatype: "image", data: <<255>>, caption: "dinner"},
          %ExironClient.MediaItem{datatype: "image", data: <<254>>, caption: "@xeba thoughts?"}
        ]
    }

    assert :ok = run_prepared_message(message, ctx.state, ctx.queue)
    assert_receive {:llm_context, context}
    assert context_text(context) =~ "dinner\n\n thoughts?"
    assert Conversations.get_by_message(message).request_text == "dinner\n\n@xeba thoughts?"
  end

  test "uncaptioned routed media uses the fallback without sending bytes to the AI", ctx do
    message = %{media("file", 6, " \n ") | msgtype: "request", req_id: "uncaptioned"}
    assert :ok = run_prepared_message(message, ctx.state, ctx.queue)
    refute_received {:llm_context, _}

    assert_receive {:reply_text, ^message,
                    "I can currently respond only to text messages or media captions."}

    assert Conversations.get_by_message(message).request_text == nil
  end

  defp media(datatype, id, caption) do
    %ExironClient.Message{
      msgtype: "message",
      message_id: id,
      service_id: 1,
      chat_id: 910,
      datatype: datatype,
      data: <<255, 0, 254>>,
      caption: caption
    }
  end

  defp context_text(context) do
    context.messages
    |> Enum.filter(&(&1.role == :user))
    |> Enum.flat_map(& &1.content)
    |> Enum.map_join("\n", & &1.text)
  end
end
