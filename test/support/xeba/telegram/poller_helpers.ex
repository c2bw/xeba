defmodule Xeba.Telegram.PollerHelpers do
  import ExUnit.Callbacks

  alias Xeba.Telegram.{JobQueue, Poller, PollerHarness}

  def start_message_queue do
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    start_supervised!(
      Supervisor.child_spec(
        {JobQueue, [name: {:global, make_ref()}, task_supervisor: tasks]},
        id: make_ref()
      )
    )
  end

  def run_prepared_message(message, state, queue) do
    state =
      state
      |> Map.put_new(:timer_owner, self())
      |> Map.put(:test_random_seed, :rand.export_seed())

    server = start_supervised!(Supervisor.child_spec({PollerHarness, state}, id: make_ref()))
    Poller.handle_message(message, server, queue)
  end
end
