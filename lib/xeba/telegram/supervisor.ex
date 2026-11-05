defmodule Xeba.Telegram.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Xeba.Telegram.Poller, opts},
      {Xeba.Telegram.JobSupervisor, []},
      {Xeba.Telegram.ExironSupervisor, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
