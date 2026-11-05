defmodule XebaWeb.LoginRateLimiter do
  @moduledoc "Per-node login throttling using the peer IP, never untrusted forwarded headers."
  use GenServer

  @limit 5
  @window_ms 60_000
  @max_clients 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def check(client, server \\ __MODULE__), do: GenServer.call(server, {:check, client})

  @impl true
  def init(opts) do
    {:ok,
     %{
       clients: %{},
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  @impl true
  def handle_call({:check, client}, _from, state) do
    now = state.clock.()
    clients = Map.reject(state.clients, fn {_client, {_count, expires}} -> expires <= now end)

    case Map.get(clients, client) do
      {count, expires} when count >= @limit ->
        {:reply, {:error, max(1, ceil((expires - now) / 1_000))}, %{state | clients: clients}}

      nil when map_size(clients) >= @max_clients ->
        {:reply, {:error, 60}, %{state | clients: clients}}

      entry ->
        {count, expires} = entry || {0, now + @window_ms}
        {:reply, :ok, %{state | clients: Map.put(clients, client, {count + 1, expires})}}
    end
  end
end
