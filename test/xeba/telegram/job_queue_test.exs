defmodule Xeba.Telegram.JobQueueTest do
  use ExUnit.Case, async: true

  alias Xeba.Telegram.JobQueue

  defp queue(opts \\ []) do
    supervisor = start_supervised!({Task.Supervisor, []})

    start_supervised!(
      {JobQueue,
       Keyword.merge(
         [
           name: {:global, make_ref()},
           task_supervisor: supervisor,
           concurrency: 2
         ],
         opts
       )}
    )
  end

  test "a blocked chat does not block another chat, while same-chat jobs stay ordered" do
    queue = queue()
    owner = self()

    JobQueue.submit(
      :a,
      fn ->
        send(owner, {:first, self()})
        receive do: (:finish -> :ok)
      end,
      {owner, :first},
      queue
    )

    assert_receive {:first, first}

    JobQueue.submit(
      :a,
      fn ->
        send(owner, :second_started)
        :ok
      end,
      {owner, :second},
      queue
    )

    JobQueue.submit(:b, fn -> :ok end, {owner, :other}, queue)
    assert_receive {:other, :ok}
    refute_received :second_started
    send(first, :finish)
    assert_receive {:first, :ok}
    assert_receive :second_started
    assert_receive {:second, :ok}
  end

  test "capacity rejects excess work instead of growing the queue" do
    queue = queue(capacity: 1)
    owner = self()

    JobQueue.submit(
      :a,
      fn ->
        send(owner, {:worker, self()})
        receive do: (:finish -> :ok)
      end,
      {owner, :first},
      queue
    )

    assert_receive {:worker, worker}

    assert {:error, :busy} =
             JobQueue.submit(
               :b,
               fn -> flunk("excess job must not run") end,
               {owner, :excess},
               queue
             )

    assert_receive {:excess, {:error, :busy}}
    send(worker, :finish)
    assert_receive {:first, :ok}
  end

  test "timed-out work is terminated and the next job for that chat can run" do
    queue = queue(timeout: 50)
    owner = self()

    JobQueue.submit(
      :a,
      fn ->
        send(owner, {:worker, self()})
        receive do: (:never -> :ok)
      end,
      {owner, :slow},
      queue
    )

    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    JobQueue.submit(:a, fn -> :ok end, {owner, :next}, queue)
    assert_receive {:slow, {:error, :worker_timeout}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert_receive {:next, :ok}
  end

  test "fire-and-forget callers also receive admission errors" do
    queue = queue(capacity: 1)
    owner = self()

    assert :ok =
             JobQueue.submit(
               :a,
               fn ->
                 send(owner, {:blocked, self()})
                 receive do: (:finish -> :ok)
               end,
               {owner, :first},
               queue
             )

    assert_receive {:blocked, worker}
    assert {:error, :busy} = JobQueue.submit(:b, fn -> flunk("must not run") end, nil, queue)
    send(worker, :finish)
    assert_receive {:first, :ok}
  end

  test "submission reports an unavailable queue instead of success" do
    assert {:error, :queue_unavailable} =
             JobQueue.submit(:a, fn -> :ok end, nil, {:global, make_ref()})
  end

  test "worker failure fails its caller and releases that chat" do
    queue = queue()
    owner = self()
    JobQueue.submit(:a, fn -> exit(:shutdown) end, {owner, :failed}, queue)
    JobQueue.submit(:a, fn -> :ok end, {owner, :next}, queue)
    assert_receive {:failed, {:error, :worker_failed}}
    assert_receive {:next, :ok}
  end

  test "a waiting SDK caller receives an exit if the queue stops" do
    queue = queue()
    owner = self()

    start_supervised!(
      {Task,
       fn ->
         result =
           try do
             JobQueue.run(
               :a,
               fn ->
                 send(owner, :started)
                 receive do: (:finish -> :ok)
               end,
               queue
             )
           catch
             :exit, _ -> :queue_stopped
           end

         send(owner, {:caller_result, result})
       end}
    )

    assert_receive :started
    Process.exit(queue, :kill)
    assert_receive {:caller_result, :queue_stopped}
  end
end
