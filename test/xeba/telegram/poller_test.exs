defmodule Xeba.Telegram.PollerTest do
  use Xeba.DataCase, async: false

  import Xeba.Telegram.PollerHelpers

  setup do
    {:ok, message_queue: start_message_queue()}
  end

  alias Xeba.Conversations
  alias Xeba.Telegram.{Delivery, FollowUp, Poller}

  test "validates required configuration" do
    config = [
      base_url: "https://exiron.example",
      hook_token: "token",
      ai_endpoint: "https://ai.example/v1",
      ai_api_key: "secret",
      model: "test-model"
    ]

    assert :ok = Poller.validate_config(config)

    for key <- [:base_url, :hook_token, :ai_api_key, :model] do
      expected_error = "missing #{key} configuration"

      assert {:error, ^expected_error} =
               config
               |> Keyword.put(key, nil)
               |> Poller.validate_config()
    end

    assert :ok = Poller.validate_config(Keyword.put(config, :ai_endpoint, nil))
    assert :ok = Poller.validate_config(Keyword.put(config, :ai_endpoint, "   "))
  end

  test "uses the chat system prompt for ordinary replies", %{message_queue: message_queue} do
    chat_id = 801
    assert {:ok, _setting} = Conversations.update_system_prompt(chat_id, "Reply as {{bot_name}}")
    assert {:ok, _setting} = Conversations.set_autonomous_enabled(chat_id, false)

    message = %ExironClient.Message{
      req_id: "custom-prompt-reply",
      msgtype: "request",
      chat_id: chat_id,
      datatype: "text",
      data: "xeba hello"
    }

    state = %{
      enabled: true,
      client: %{owner: self()},
      exiron: Xeba.Telegram.PollerExironFake,
      llm: Xeba.Telegram.PollerPromptLLMFake,
      model: "test-model",
      llm_options: [test_pid: self()],
      bot_name: "xeba",
      autonomous_timers: %{}
    }

    assert :ok = run_prepared_message(message, state, message_queue)
    assert_receive {:llm_system_prompt, "Reply as xeba"}
  end

  test "uses the chat system prompt for autonomous replies" do
    chat_id = 802

    assert {:ok, _setting} =
             Conversations.update_system_prompt(chat_id, "Autonomous {{bot_name}}")

    state = %{
      enabled: true,
      client: %{owner: self()},
      exiron: Xeba.Telegram.PollerExironFake,
      llm: Xeba.Telegram.PollerPromptLLMFake,
      model: "test-model",
      llm_options: [test_pid: self()],
      bot_name: "xeba",
      sticker_reply_delay_ms: 0,
      autonomous_timers: %{}
    }

    assert {:noreply, ^state} = Poller.handle_info({:autonomous_message, chat_id}, state)
    assert_receive {:llm_system_prompt, "Autonomous xeba"}
  end

  test "does not acknowledge a message that could not be persisted", %{
    message_queue: message_queue
  } do
    message = %ExironClient.Message{
      req_id: "invalid-message",
      msgtype: "request",
      datatype: nil,
      data: "hello"
    }

    state = %{
      enabled: true,
      model: "test-model",
      bot_name: "xeba",
      autonomous_timers: %{}
    }

    assert {:error, :message_persistence_failed} =
             run_prepared_message(message, state, message_queue)
  end

  test "runs the Exiron connection under the Telegram supervisor" do
    children = Supervisor.which_children(Xeba.Telegram.Supervisor)

    assert Enum.any?(children, fn
             {_id, pid, :worker, modules} ->
               pid == Process.whereis(Poller) and Poller in modules

             _child ->
               false
           end)

    assert Enum.any?(children, fn
             {_id, pid, :supervisor, modules} ->
               pid == Process.whereis(Xeba.Telegram.ExironSupervisor) and
                 Xeba.Telegram.ExironSupervisor in modules

             _child ->
               false
           end)
  end

  test "restarts the Exiron supervisor when the business poller restarts" do
    poller = Process.whereis(Poller)
    exiron_supervisor = Process.whereis(Xeba.Telegram.ExironSupervisor)
    poller_ref = Process.monitor(poller)
    exiron_supervisor_ref = Process.monitor(exiron_supervisor)

    Process.exit(poller, :kill)

    assert_receive {:DOWN, ^poller_ref, :process, ^poller, :killed}

    assert_receive {:DOWN, ^exiron_supervisor_ref, :process, ^exiron_supervisor, :shutdown}

    children = Supervisor.which_children(Xeba.Telegram.Supervisor)
    restarted_poller = Process.whereis(Poller)
    restarted_exiron_supervisor = Process.whereis(Xeba.Telegram.ExironSupervisor)

    assert is_pid(restarted_poller)
    assert is_pid(restarted_exiron_supervisor)
    refute restarted_poller == poller
    refute restarted_exiron_supervisor == exiron_supervisor

    assert Enum.any?(children, fn
             {_id, pid, :worker, modules} ->
               pid == restarted_poller and Poller in modules

             _child ->
               false
           end)

    assert Enum.any?(children, fn
             {_id, pid, :supervisor, modules} ->
               pid == restarted_exiron_supervisor and
                 Xeba.Telegram.ExironSupervisor in modules

             _child ->
               false
           end)
  end

  test "uses a five-to-seven-hour delay for recurring autonomous messages" do
    for _ <- 1..100 do
      delay = Poller.recurring_autonomous_delay_ms()

      assert delay >= :timer.hours(5)
      assert delay <= :timer.hours(7)
      assert rem(delay, :timer.hours(1)) == 0
    end
  end

  test "schedules a follow-up response on one out of four response rolls" do
    assert FollowUp.response?(1)
    refute FollowUp.response?(2)
    refute FollowUp.response?(3)
    refute FollowUp.response?(4)
  end

  test "uses a sticker response on one out of two response rolls" do
    assert Delivery.sticker_response?(1)
    refute Delivery.sticker_response?(2)
  end

  test "plans a sticker response by removing the trailing emoji and choosing a matching sticker" do
    stickers = [
      %{emoji: "\u{1F525}", emoji_list: ["\u{1F525}", "\u{1F923}"], sticker_id: "fire-1"},
      %{emoji: "\u{1F525}", emoji_list: ["\u{1F525}", "\u{1F923}"], sticker_id: "fire-2"},
      %{emoji: "\u{2728}", emoji_list: ["\u{2728}"], sticker_id: "sparkle-1"}
    ]

    picker = fn candidates -> Enum.at(candidates, 1) end

    assert {:sticker, "That's perfect", %{sticker_id: "fire-2"}} =
             Delivery.sticker_response_plan("That's perfect \u{1F923}", stickers, 1, picker)
  end

  test "keeps the original response when sticker replacement is not eligible" do
    stickers = [%{emoji: "\u{1F525}", emoji_list: ["\u{1F525}"], sticker_id: "fire-1"}]
    picker = fn candidates -> hd(candidates) end

    assert :text ==
             Delivery.sticker_response_plan("That's perfect \u{1F525}", stickers, 2, picker)

    assert :text == Delivery.sticker_response_plan("That's perfect \u{2728}", stickers, 1, picker)
    assert :text == Delivery.sticker_response_plan("That's perfect", stickers, 1, picker)
    assert :text == Delivery.sticker_response_plan("\u{1F525}", stickers, 1, picker)
  end

  test "sends sticker replies as a text reply followed by a chat push", %{
    message_queue: message_queue
  } do
    owner = self()
    chat_id = 42
    :rand.seed(:exsss, {4, 4, 4})
    assert {:ok, _setting} = Conversations.set_autonomous_enabled(chat_id, false)

    assert {:ok, _exchange} =
             Conversations.create_from_message(
               %ExironClient.Message{
                 req_id: "observed-sticker",
                 msgtype: "message",
                 chat_id: chat_id,
                 datatype: "sticker",
                 sticker_id: "fire-sticker",
                 sticker_emoji: "\u{1F525}",
                 emoji_list: ["\u{1F525}"],
                 data: "sticker-bytes"
               },
               "test-model"
             )

    message = %ExironClient.Message{
      req_id: "request-1",
      msgtype: "request",
      chat_id: chat_id,
      datatype: "text",
      data: "xeba say something",
      from: %{"first_name" => "Ada"}
    }

    state = %{
      enabled: true,
      client: %{owner: owner},
      exiron: Xeba.Telegram.PollerExironFake,
      llm: Xeba.Telegram.PollerLLMFake,
      model: "test-model",
      llm_options: [endpoint: "https://ai.example/v1", api_key: "secret"],
      bot_name: "xeba",
      sticker_reply_delay_ms: 0,
      autonomous_timers: %{}
    }

    assert :ok = run_prepared_message(message, state, message_queue)

    assert_receive {:reply_text, ^message, "Here you go"}
    assert_receive {:push_sticker, ^chat_id, "fire-sticker", "\u{1F525}"}
    refute_receive {:reply_sticker, _message, _sticker_id, _emoji}

    assert %{
             model: "test-model",
             input_tokens: 1,
             output_tokens: 4,
             total_tokens: 5,
             tokens_used_at: %DateTime{}
           } = Conversations.get_by_message(message)
  end

  test "delays stickers after pushed text responses" do
    owner = self()
    chat_id = 44
    :rand.seed(:exsss, {4, 4, 4})

    assert {:ok, _setting} = Conversations.set_autonomous_enabled(chat_id, true)

    assert {:ok, _exchange} =
             Conversations.create_from_message(
               %ExironClient.Message{
                 req_id: "observed-push-sticker",
                 msgtype: "message",
                 chat_id: chat_id,
                 datatype: "sticker",
                 sticker_id: "fire-sticker",
                 sticker_emoji: "\u{1F525}",
                 emoji_list: ["\u{1F525}"],
                 data: "sticker-bytes"
               },
               "test-model"
             )

    state = %{
      enabled: true,
      client: %{owner: owner},
      exiron: Xeba.Telegram.PollerExironFake,
      llm: Xeba.Telegram.PollerLLMFake,
      model: "test-model",
      llm_options: [endpoint: "https://ai.example/v1", api_key: "secret"],
      bot_name: "xeba",
      sticker_reply_delay_ms: 50,
      autonomous_timers: %{}
    }

    started_at = System.monotonic_time(:millisecond)
    assert {:noreply, ^state} = Poller.handle_info({:autonomous_message, chat_id}, state)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert_receive {:push_text, ^chat_id, "Here you go"}
    assert_receive {:push_sticker, ^chat_id, "fire-sticker", "\u{1F525}"}, 100
    assert elapsed_ms >= 50
  end

  test "replaces empty generated replies with an ellipsis", %{message_queue: message_queue} do
    owner = self()
    chat_id = 43
    assert {:ok, _setting} = Conversations.set_autonomous_enabled(chat_id, false)

    message = %ExironClient.Message{
      req_id: "empty-response-request",
      msgtype: "request",
      chat_id: chat_id,
      datatype: "text",
      data: "xeba say something",
      from: %{"first_name" => "Ada"}
    }

    state = %{
      enabled: true,
      client: %{owner: owner},
      exiron: Xeba.Telegram.PollerExironFake,
      llm: Xeba.Telegram.PollerEmptyLLMFake,
      model: "test-model",
      llm_options: [endpoint: "https://ai.example/v1", api_key: "secret"],
      bot_name: "xeba",
      autonomous_timers: %{}
    }

    assert :ok = run_prepared_message(message, state, message_queue)
    assert_receive {:reply_text, ^message, "..."}

    assert %{response_text: "..."} = Conversations.get_by_message(message)
  end

  test "removes a weekday-prefixed first line from delivered and stored replies", %{
    message_queue: message_queue
  } do
    owner = self()
    chat_id = 45
    assert {:ok, _setting} = Conversations.set_autonomous_enabled(chat_id, false)

    message = %ExironClient.Message{
      req_id: "weekday-response-request",
      msgtype: "request",
      chat_id: chat_id,
      datatype: "text",
      data: " \nxeba say something\t ",
      from: %{"first_name" => "Ada"}
    }

    state = %{
      enabled: true,
      client: %{owner: owner},
      exiron: Xeba.Telegram.PollerExironFake,
      llm: Xeba.Telegram.PollerWeekdayLLMFake,
      model: "test-model",
      llm_options: [endpoint: "https://ai.example/v1", api_key: "secret"],
      bot_name: "xeba",
      autonomous_timers: %{}
    }

    assert :ok = run_prepared_message(message, state, message_queue)
    assert_receive {:reply_text, ^message, "The response body"}

    assert %{request_text: "xeba say something", response_text: "The response body"} =
             Conversations.get_by_message(message)
  end

  test "schedules follow-ups only for eligible generated replies" do
    assert FollowUp.schedule?([follow_up_candidate?: true], 1)

    refute FollowUp.schedule?([], 1)
    refute FollowUp.schedule?([follow_up_candidate?: true], 2)
    refute FollowUp.schedule?([follow_up_candidate?: true, schedule_follow_up?: false], 1)
  end

  test "timer status remains available while the poller mailbox is busy" do
    pid = Process.whereis(Poller)
    assert is_pid(pid)

    :sys.suspend(pid)
    on_exit(fn -> :sys.resume(pid) end)

    started_at = System.monotonic_time(:millisecond)
    assert Poller.timer_status() == %{}
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed < 100
  end

  test "reports when the configured poller is disabled" do
    assert Poller.connection_status() == :disabled
  end
end
