defmodule Xeba.Telegram.ExironSupervisor do
  @moduledoc false

  use Supervisor

  alias Xeba.Telegram.Poller

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      case Poller.managed_poller_child_spec() do
        :ignore -> []
        child_spec -> [child_spec]
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
