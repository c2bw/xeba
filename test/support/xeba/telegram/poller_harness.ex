defmodule Xeba.Telegram.PollerHarness do
  @moduledoc false
  use GenServer

  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:prepare_message, _message} = request, from, state) do
    {:reply, work, state} = Xeba.Telegram.Poller.handle_call(request, from, state)
    seed = Map.get(state, :test_random_seed, :undefined)

    {:reply,
     fn ->
       if seed != :undefined, do: :rand.seed(seed)
       work.()
     end, state}
  end
end
