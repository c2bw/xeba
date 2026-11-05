defmodule Xeba.Telegram.PollerReliabilityTest do
  use Xeba.DataCase

  import Xeba.Telegram.PollerHelpers

  alias Xeba.Conversations
  alias Xeba.Telegram.Poller

  setup do
    {:ok, _} = Conversations.set_autonomous_enabled(99001, false)
    failures = start_supervised!({Agent, fn -> %{} end})

    state = %{
      enabled: true,
      client: %{owner: self(), failures: failures},
      exiron: Xeba.Telegram.PollerRetryExironFake,
      llm: Xeba.Telegram.PollerPromptLLMFake,
      model: "test-model",
      llm_options: [test_pid: self()],
      bot_name: "xeba",
      autonomous_timers: %{},
      sticker_reply_delay_ms: 0
    }

    message = %ExironClient.Message{
      req_id: "reliability",
      msgtype: "request",
      chat_id: 99001,
      datatype: "text",
      data: "hello"
    }

    {:ok,
     state: state, message: message, failures: failures, message_queue: start_message_queue()}
  end

  test "returns a retryable error and reuses the generated response on retry", ctx do
    Agent.update(ctx.failures, fn _ -> %{text: 1} end)
    assert {:error, :reply_delivery_failed} = process(ctx)
    assert_receive {:llm_system_prompt, _}
    assert_receive {:reply_text, _, "Prompt received"}
    assert Conversations.get_by_message(ctx.message).status == "reply_failed"

    assert :ok = process(ctx)
    refute_receive {:llm_system_prompt, _}
    assert_receive {:reply_text, _, "Prompt received"}
    exchange = Conversations.get_by_message(ctx.message)
    assert exchange.status == "completed"
    assert exchange.error == nil
    assert exchange.total_tokens == 3

    assert :ok = process(ctx)
    refute_receive {:reply_text, _, _}
  end

  test "replayed observed and no-answer messages remain terminal", ctx do
    for status <- ["observed", "no_answer", "failed"] do
      message = %{ctx.message | req_id: status}
      {:ok, exchange} = Conversations.create_from_message(message, "test-model")
      {:ok, _} = Conversations.update_exchange(exchange, %{status: status})
      assert :ok = process(%{ctx | message: message})
      refute_received {:llm_system_prompt, _}
      refute_received {:reply_text, _, _}
    end
  end

  test "replacement preserves delivery identity and cannot cause another generated reply", ctx do
    message = %{ctx.message | req_id: "andrebot-id", data: "hello andrebot"}
    ctx = %{ctx | message: message}
    assert :ok = process(ctx)
    assert_receive {:llm_system_prompt, _}
    assert_receive {:reply_text, _, _}
    assert {:ok, 1} = Conversations.replace_database_text("andrebot", "xeba")
    assert Conversations.get_by_message(message).req_id == "andrebot-id"
    assert :ok = process(ctx)
    refute_received {:llm_system_prompt, _}
    refute_received {:reply_text, _, _}
    assert length(Conversations.list_exchanges_for_chat(99001)) == 1
  end

  test "replacement refuses to change a response that is waiting to be retried", ctx do
    Agent.update(ctx.failures, fn _ -> %{text: 1} end)
    assert {:error, :reply_delivery_failed} = process(ctx)
    assert_receive {:reply_text, _, "Prompt received"}

    assert {:error, :delivery_in_progress} =
             Conversations.preview_database_text_replacement("Prompt")

    assert {:error, :delivery_in_progress} =
             Conversations.replace_database_text("Prompt", "Redacted")

    exchange = Conversations.get_by_message(ctx.message)
    assert exchange.response_text == "Prompt received"
    assert exchange.delivery_state["plan"]["text"] == "Prompt received"
    assert :ok = process(ctx)
    assert_receive {:reply_text, _, "Prompt received"}
    assert {:ok, 1} = Conversations.replace_database_text("Prompt", "Redacted")
    assert :ok = process(ctx)
    refute_received {:reply_text, _, _}
  end

  test "retries reconcile stale and legacy unsent plans with the stored response", ctx do
    for mode <- [:stale, :legacy] do
      Agent.update(ctx.failures, fn _ -> %{text: 1} end)
      ctx = %{ctx | message: %{ctx.message | req_id: "plan-#{mode}"}}
      assert {:error, :reply_delivery_failed} = process(ctx)
      assert_receive {:reply_text, _, "Prompt received"}
      exchange = Conversations.get_by_message(ctx.message)

      delivery_state =
        if mode == :legacy,
          do:
            update_in(exchange.delivery_state, ["plan"], &Map.delete(&1, "response_fingerprint")),
          else: exchange.delivery_state

      {:ok, _} =
        Conversations.update_exchange(exchange, %{
          response_text: "Redacted received",
          delivery_state: delivery_state
        })

      assert :ok = process(ctx)
      assert_receive {:reply_text, _, "Redacted received"}
      assert Conversations.get_by_message(ctx.message).status == "completed"
    end
  end

  test "autonomous text delivery retries the saved response without another AI call", ctx do
    {:ok, _} = Conversations.set_autonomous_enabled(99001, true)
    Agent.update(ctx.failures, fn _ -> %{text: 1} end)
    state = Map.put(ctx.state, :autonomous_retry_delay_ms, 0)

    assert {:noreply, _} = Poller.handle_info({:autonomous_message, 99001}, state)
    assert_receive {:llm_system_prompt, _}
    assert_receive {:push_text, 99001, "Prompt received"}
    [exchange] = Conversations.list_exchanges_for_chat(99001)
    assert exchange.status == "reply_failed"
    assert_receive {:retry_autonomous_delivery, id}
    assert id == exchange.id
    workers = start_supervised!({Task.Supervisor, []})

    queue =
      start_supervised!(
        {Xeba.Telegram.JobQueue, [name: {:global, make_ref()}, task_supervisor: workers]}
      )

    background_state =
      Map.merge(state, %{background_jobs: true, timer_owner: self(), job_queue: queue})

    assert {:noreply, _} = Poller.handle_info({:retry_autonomous_delivery, id}, background_state)
    assert :finished = Xeba.Telegram.JobQueue.run(99001, fn -> :finished end, queue)
    assert_receive {:push_text, 99001, "Prompt received"}
    refute_received {:llm_system_prompt, _}
    [completed] = Conversations.list_exchanges_for_chat(99001)
    assert completed.id == id
    assert completed.status == "completed"
    assert completed.delivery_state["autonomous_attempts"] == 2
    assert completed.total_tokens == 3
    Poller.handle_info({:retry_autonomous_delivery, id}, state)
    refute_received {:push_text, _, _}
  end

  test "autonomous retries stop after four attempts and recover eligible failures on startup",
       ctx do
    {:ok, _} = Conversations.set_autonomous_enabled(99001, true)
    Agent.update(ctx.failures, fn _ -> %{text: 10} end)
    state = Map.put(ctx.state, :autonomous_retry_delay_ms, 0)
    Poller.handle_info({:autonomous_message, 99001}, state)
    assert_receive {:retry_autonomous_delivery, id}
    assert id in Conversations.retryable_autonomous_delivery_ids(4)
    Poller.handle_info(:resume_autonomous_deliveries, state)
    assert_receive {:retry_autonomous_delivery, ^id}

    for _ <- 1..3 do
      Poller.handle_info({:retry_autonomous_delivery, id}, state)
    end

    failed = Xeba.Repo.get!(Xeba.Conversations.Exchange, id)
    assert failed.status == "reply_failed"
    assert failed.delivery_state["autonomous_attempts"] == 4
    refute id in Conversations.retryable_autonomous_delivery_ids(4)
    for _ <- 1..4, do: assert_receive({:push_text, 99001, _})
    Poller.handle_info({:retry_autonomous_delivery, id}, state)
    refute_received {:push_text, _, _}
  end

  test "retry queue overload preserves the delivery attempt budget", ctx do
    {:ok, _} = Conversations.set_autonomous_enabled(99001, true)
    {:ok, exchange} = Conversations.create_autonomous(99001, "test-model")

    {:ok, _} =
      Conversations.update_exchange(exchange, %{
        status: "reply_failed",
        response_text: "Saved response",
        delivery_state: %{"autonomous_attempts" => 1}
      })

    workers = start_supervised!({Task.Supervisor, []})

    queue =
      start_supervised!(
        {Xeba.Telegram.JobQueue,
         [name: {:global, make_ref()}, task_supervisor: workers, capacity: 0]}
      )

    state = Map.merge(ctx.state, %{background_jobs: true, job_queue: queue})
    Poller.handle_info({:retry_autonomous_delivery, exchange.id}, state)

    assert Xeba.Repo.get!(Xeba.Conversations.Exchange, exchange.id).delivery_state[
             "autonomous_attempts"
           ] == 1

    refute_received {:push_text, _, _}
    Poller.handle_info({:retry_autonomous_delivery, exchange.id}, ctx.state)
    assert_receive {:push_text, 99001, "Saved response"}
    refute_received {:llm_system_prompt, _}
  end

  test "autonomous sticker retries keep confirmed text and respect disabled autonomy", ctx do
    {:ok, _} = Conversations.set_autonomous_enabled(99001, true)
    {:ok, exchange} = Conversations.create_autonomous(99001, "test-model")

    {:ok, exchange} =
      Conversations.update_exchange(exchange, %{
        status: "reply_failed",
        response_text: "Saved reply",
        delivery_state: %{
          "text_sent" => true,
          "autonomous_attempts" => 1,
          "plan" => %{"text" => "Saved reply", "sticker_id" => "saved-sticker", "emoji" => "🔥"}
        }
      })

    state = Map.put(ctx.state, :autonomous_retry_delay_ms, 0)
    {:ok, _} = Conversations.set_autonomous_enabled(99001, false)
    Poller.handle_info({:retry_autonomous_delivery, exchange.id}, state)
    refute_received {:push_sticker, _, _, _}
    {:ok, _} = Conversations.set_autonomous_enabled(99001, true)
    Poller.handle_info({:retry_autonomous_delivery, exchange.id}, state)
    assert_receive {:push_sticker, 99001, "saved-sticker", "🔥"}
    refute_received {:push_text, _, _}
    refute_received {:llm_system_prompt, _}
    assert Xeba.Repo.get!(Xeba.Conversations.Exchange, exchange.id).status == "completed"
  end

  test "a queued follow-up respects the current disabled setting", ctx do
    assert {:noreply, _} =
             Poller.handle_info({:follow_up_response, 99001, "follow up"}, ctx.state)

    refute_received {:llm_system_prompt, _}
    refute_received {:push_text, _, _}
  end

  test "manual send reports disabled and does not pretend to queue work" do
    assert :sys.get_state(Poller).enabled == false
    assert {:error, :poller_disabled} = Poller.send_autonomous_now(99001)
  end

  test "manual send keeps its timer when admission fails and resets it only on acceptance", ctx do
    {:ok, _} = Conversations.create_from_message(ctx.message, "test-model")
    {:ok, _} = Conversations.set_autonomous_enabled(99001, true)
    workers = start_supervised!({Task.Supervisor, []})

    queue =
      start_supervised!(
        {Xeba.Telegram.JobQueue,
         [name: {:global, make_ref()}, task_supervisor: workers, capacity: 1]}
      )

    owner = self()

    assert :ok =
             Xeba.Telegram.JobQueue.submit(
               :blocked,
               fn ->
                 send(owner, {:blocked, self()})
                 receive do: (:finish -> :ok)
               end,
               {owner, :block},
               queue
             )

    assert_receive {:blocked, worker}

    state =
      Map.merge(ctx.state, %{
        background_jobs: true,
        job_queue: queue,
        llm_options: [
          test_pid: owner,
          before_response: fn ->
            send(owner, {:manual_worker, self()})
            receive do: (:continue -> :ok)
          end
        ]
      })

    assert {:reply, {:error, :busy}, ^state} =
             Poller.handle_call({:send_autonomous_now, 99001}, self(), state)

    send(worker, :finish)
    assert_receive {:block, :ok}

    assert {:reply, :ok, next_state} =
             Poller.handle_call({:send_autonomous_now, 99001}, self(), state)

    assert Map.has_key?(next_state.autonomous_timers, 99001)
    assert_receive {:manual_worker, manual_worker}
    ref = Process.monitor(manual_worker)
    send(manual_worker, :continue)
    assert_receive {:push_text, 99001, "Prompt received"}
    assert_receive {:DOWN, ^ref, :process, ^manual_worker, :normal}
    Poller.handle_cast({:set_autonomous_enabled, 99001, false}, next_state)
  end

  test "autonomy disabled while generating prevents delivery", ctx do
    {:ok, _} = Conversations.set_autonomous_enabled(99001, true)

    state =
      put_in(ctx.state, [:llm_options],
        test_pid: self(),
        before_response: fn ->
          Conversations.set_autonomous_enabled(99001, false)
        end
      )

    assert {:noreply, _} = Poller.handle_info({:autonomous_message, 99001}, state)
    assert_receive {:llm_system_prompt, _}
    refute_received {:push_text, _, _}

    assert [%{status: "no_answer", response_text: nil}] =
             Conversations.list_exchanges_for_chat(99001)
  end

  test "prepared jobs let another chat finish while one AI request is blocked", ctx do
    {:ok, _} = Conversations.set_autonomous_enabled(99002, false)
    workers = start_supervised!({Task.Supervisor, []})
    callers = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: :callers))

    queue =
      start_supervised!(
        {Xeba.Telegram.JobQueue, [name: {:global, make_ref()}, task_supervisor: workers]}
      )

    state = %{ctx.state | llm: Xeba.Telegram.PollerBlockingLLMFake}

    server =
      start_supervised!({Xeba.Telegram.PollerHarness, Map.put(state, :timer_owner, self())})

    first =
      Task.Supervisor.async_nolink(callers, fn ->
        Poller.handle_message(ctx.message, server, queue)
      end)

    assert_receive {:generation_waiting, first_worker}

    other_message = %{ctx.message | req_id: "other-chat", chat_id: 99002}

    other =
      Task.Supervisor.async_nolink(callers, fn ->
        Poller.handle_message(other_message, server, queue)
      end)

    assert_receive {:generation_waiting, other_worker}
    send(other_worker, :finish)
    other_ref = other.ref
    assert_receive {^other_ref, :ok}
    assert Conversations.get_by_message(other_message).status == "completed"
    assert Conversations.get_by_message(ctx.message).status == "pending"

    send(first_worker, :finish)
    first_ref = first.ref
    assert_receive {^first_ref, :ok}
  end

  test "partial sticker failure retries only the undelivered sticker", ctx do
    {:ok, _} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "sticker",
          msgtype: "message",
          chat_id: 99001,
          datatype: "sticker",
          sticker_id: "fire",
          sticker_emoji: "🔥",
          emoji_list: ["🔥"],
          data: "bytes"
        },
        "test-model"
      )

    Agent.update(ctx.failures, fn _ -> %{sticker: 1} end)
    :rand.seed(:exsss, {4, 4, 4})
    ctx = put_in(ctx.state.llm, Xeba.Telegram.PollerLLMFake)

    assert {:error, :reply_delivery_failed} = process(ctx)
    assert_receive {:reply_text, _, "Here you go"}
    assert_receive {:push_sticker, 99001, "fire", "🔥"}
    assert :ok = process(ctx)
    refute_receive {:reply_text, _, _}
    assert_receive {:push_sticker, 99001, "fire", "🔥"}
    assert Conversations.get_by_message(ctx.message).status == "completed"
  end

  defp process(ctx), do: run_prepared_message(ctx.message, ctx.state, ctx.message_queue)
end
