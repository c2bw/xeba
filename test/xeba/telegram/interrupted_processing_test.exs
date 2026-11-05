defmodule Xeba.Telegram.InterruptedProcessingTest do
  use Xeba.DataCase

  import Xeba.Telegram.PollerHelpers

  alias Xeba.Conversations
  alias Xeba.Conversations.Exchange
  alias Xeba.Repo
  alias Xeba.Telegram.{JobQueue, Poller}

  setup do
    failures = start_supervised!({Agent, fn -> %{} end})
    workers = start_supervised!({Task.Supervisor, []})
    queue = start_supervised!({JobQueue, [name: {:global, make_ref()}, task_supervisor: workers]})

    state = %{
      enabled: true,
      client: %{owner: self(), failures: failures},
      exiron: Xeba.Telegram.PollerRetryExironFake,
      llm: Xeba.Telegram.PollerPromptLLMFake,
      llm_options: [test_pid: self()],
      model: "test-model",
      bot_name: "xeba",
      autonomous_timers: %{},
      timer_owner: self(),
      sticker_reply_delay_ms: 0,
      autonomous_retry_delay_ms: 0
    }

    {:ok, state: state, queue: queue}
  end

  test "pending observations stay observed on replay, including legacy rows", %{
    state: state,
    queue: queue
  } do
    {:ok, _} = Conversations.set_autonomous_enabled(601, false)

    for {id, data, datatype, decision} <- [
          {1, "ordinary conversation", "text", %{}},
          {2, "xeba appears later", "text", %{"response_requested" => false}},
          {3, "file bytes", "file", %{}}
        ] do
      message = %ExironClient.Message{
        req_id: nil,
        message_id: id,
        service_id: 1,
        msgtype: "message",
        chat_id: 601,
        datatype: datatype,
        data: data
      }

      {:ok, _} = Conversations.create_from_message(message, "test-model", decision)
      assert :ok = run_prepared_message(message, state, queue)
      assert Conversations.get_by_message(message).status == "observed"
    end

    refute_received {:llm_system_prompt, _}
    refute_received {:push_text, _, _}
  end

  test "pending requests still generate an answer on replay", %{state: state, queue: queue} do
    {:ok, _} = Conversations.set_autonomous_enabled(601, false)

    for {id, req_id, data, decision} <- [
          {1, "routed", "hello", %{}},
          {2, nil, "xeba hello", %{}},
          {3, nil, "hello", %{"response_requested" => true}}
        ] do
      message = %ExironClient.Message{
        req_id: req_id,
        message_id: id,
        service_id: 1,
        msgtype: if(req_id, do: "request", else: "message"),
        chat_id: 601,
        datatype: "text",
        data: data
      }

      {:ok, _} = Conversations.create_from_message(message, "test-model", decision)
      assert :ok = run_prepared_message(message, state, queue)
      assert_receive {:llm_system_prompt, _}
      assert Conversations.get_by_message(message).status == "completed"
    end
  end

  test "a timed-out autonomous worker is recovered without regenerating its response", %{
    state: state
  } do
    {:ok, _} = Conversations.set_autonomous_enabled(602, true)
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: :timeout_tasks))

    queue =
      start_supervised!(
        Supervisor.child_spec(
          {JobQueue, [name: {:global, make_ref()}, task_supervisor: tasks, timeout: 500]},
          id: :timeout_queue
        )
      )

    worker_state = %{state | exiron: Xeba.Telegram.PollerInterruptedExironFake}

    :ok =
      JobQueue.submit(
        602,
        fn -> Poller.handle_info({:autonomous_message, 602}, worker_state) end,
        {self(), :interrupted},
        queue
      )

    assert_receive {:llm_system_prompt, _}
    assert_receive {:autonomous_delivery_waiting, worker, 602, "Prompt received"}
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 2_000
    assert_receive {:interrupted, {:error, :worker_timeout}}
    [exchange] = Conversations.list_exchanges_for_chat(602)
    assert exchange.status == "pending"
    assert exchange.id in Conversations.retryable_autonomous_delivery_ids(4)
    recover(exchange.id, 602, state, queue)
    assert_receive {:push_text, 602, "Prompt received"}
    refute_received {:llm_system_prompt, _}
    assert Repo.get!(Exchange, exchange.id).status == "completed"
  end

  test "recovery queued behind a live worker does not duplicate delivery", %{
    state: state,
    queue: queue
  } do
    {:ok, _} = Conversations.set_autonomous_enabled(603, true)
    worker_state = %{state | exiron: Xeba.Telegram.PollerInterruptedExironFake}

    JobQueue.submit(
      603,
      fn -> Poller.handle_info({:autonomous_message, 603}, worker_state) end,
      {self(), :live_job},
      queue
    )

    assert_receive {:autonomous_delivery_waiting, worker, 603, _}
    [exchange] = Conversations.list_exchanges_for_chat(603)
    background = Map.merge(state, %{background_jobs: true, job_queue: queue})
    Poller.handle_info({:retry_autonomous_delivery, exchange.id}, background)
    send(worker, :finish)
    assert_receive {:live_job, _}
    assert :finished = JobQueue.run(603, fn -> :finished end, queue)
    assert Repo.get!(Exchange, exchange.id).status == "completed"
    assert Repo.get!(Exchange, exchange.id).delivery_state["autonomous_attempts"] == 1
    refute_received {:push_text, _, _}
  end

  test "an interruption during generation resumes the saved prompt", %{state: state, queue: queue} do
    {:ok, _} = Conversations.set_autonomous_enabled(604, true)
    owner = self()

    blocked =
      put_in(state.llm_options,
        test_pid: owner,
        before_response: fn ->
          send(owner, {:generation_waiting, self()})
          receive do: (:finish -> :ok)
        end
      )

    JobQueue.submit(
      604,
      fn -> Poller.handle_info({:follow_up_response, 604, "Saved follow-up prompt"}, blocked) end,
      {self(), :generation},
      queue
    )

    assert_receive {:llm_system_prompt, _}
    assert_receive {:generation_waiting, worker}
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert_receive {:generation, {:error, :worker_failed}}
    [exchange] = Conversations.list_exchanges_for_chat(604)
    assert exchange.delivery_state["autonomous_prompt"] == "Saved follow-up prompt"
    assert exchange.delivery_state["autonomous_attempts"] == 1

    Poller.handle_info(:resume_autonomous_deliveries, state)
    assert_receive {:retry_autonomous_delivery, id}
    assert id == exchange.id
    recover(id, 604, state, queue)
    assert_receive {:llm_system_prompt, _}
    assert_receive {:push_text, 604, "Prompt received"}
    [completed] = Conversations.list_exchanges_for_chat(604)
    assert completed.id == id
    assert completed.status == "completed"
    assert completed.delivery_state["autonomous_attempts"] == 2
  end

  test "periodic recovery does not bypass a saved retry deadline", %{state: state, queue: queue} do
    {:ok, _} = Conversations.set_autonomous_enabled(606, true)

    {:ok, exchange} =
      Conversations.create_autonomous(606, "test-model", %{
        "autonomous_attempts" => 1,
        "autonomous_retry_at" => System.system_time(:millisecond) + 60_000
      })

    {:ok, _} =
      Conversations.update_exchange(exchange, %{status: "reply_failed", response_text: "Saved"})

    recover(exchange.id, 606, state, queue)
    assert Repo.get!(Exchange, exchange.id).delivery_state["autonomous_attempts"] == 1
    refute_received {:push_text, _, _}
    refute_received {:llm_system_prompt, _}
  end

  test "orphaned pending work respects the attempt limit and confirmed deliveries", %{
    state: state,
    queue: queue
  } do
    {:ok, _} = Conversations.set_autonomous_enabled(605, true)

    for {text, delivered?, expected} <- [
          {nil, false, "failed"},
          {"Saved", false, "reply_failed"},
          {"Saved", true, "completed"}
        ] do
      {:ok, exchange} =
        Conversations.create_autonomous(605, "test-model", %{
          "autonomous_attempts" => 4,
          "text_sent" => delivered?,
          "plan" => %{"text" => text}
        })

      {:ok, _} = Conversations.update_exchange(exchange, %{response_text: text})
      recover(exchange.id, 605, state, queue)
      assert Repo.get!(Exchange, exchange.id).status == expected
    end

    refute_received {:llm_system_prompt, _}
    refute_received {:push_text, _, _}
  end

  defp recover(id, chat, state, queue) do
    background = Map.merge(state, %{background_jobs: true, job_queue: queue})
    Poller.handle_info({:retry_autonomous_delivery, id}, background)
    assert :finished = JobQueue.run(chat, fn -> :finished end, queue)
  end
end
