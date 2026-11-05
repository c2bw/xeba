defmodule Xeba.Telegram.JobSupervisor do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Task.Supervisor, name: Xeba.Telegram.Tasks},
        {Xeba.Telegram.JobQueue, task_supervisor: Xeba.Telegram.Tasks}
      ],
      strategy: :one_for_all
    )
  end
end
