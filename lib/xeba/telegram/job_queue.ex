defmodule Xeba.Telegram.JobQueue do
  @moduledoc "Bounded background work, with at most one active job per chat."
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def submit(chat_id, work, reply_to \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:submit, chat_id, work, reply_to})
  catch
    :exit, _reason -> {:error, :queue_unavailable}
  end

  def run(chat_id, work, server \\ __MODULE__) do
    GenServer.call(server, {:run, chat_id, work}, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       supervisor: Keyword.fetch!(opts, :task_supervisor),
       concurrency: Keyword.get(opts, :concurrency, 4),
       capacity: Keyword.get(opts, :capacity, 100),
       timeout: Keyword.get(opts, :timeout, 120_000),
       waiting: [],
       active: %{},
       chats: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:run, chat, work}, from, state) do
    if map_size(state.active) + length(state.waiting) >= state.capacity do
      {:reply, {:error, :busy}, state}
    else
      {:noreply, dispatch(%{state | waiting: state.waiting ++ [{chat, work, from}]})}
    end
  end

  def handle_call({:submit, chat, work, reply_to}, _from, state) do
    if map_size(state.active) + length(state.waiting) >= state.capacity do
      respond(reply_to, {:error, :busy})
      {:reply, {:error, :busy}, state}
    else
      {:reply, :ok, dispatch(%{state | waiting: state.waiting ++ [{chat, work, reply_to}]})}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    if state.active[ref] && Map.get(state.active[ref], :timed_out?, false) do
      {:noreply, state}
    else
      {:noreply, finish(state, ref, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    reason =
      if state.active[ref] && Map.get(state.active[ref], :timed_out?, false),
        do: :worker_timeout,
        else: :worker_failed

    {:noreply, finish(state, ref, {:error, reason})}
  end

  def handle_info({:timeout, ref}, state) do
    case state.active[ref] do
      nil ->
        {:noreply, state}

      job ->
        Process.exit(job.pid, :kill)
        {:noreply, %{state | active: Map.put(state.active, ref, Map.put(job, :timed_out?, true))}}
    end
  end

  defp dispatch(state) when map_size(state.active) >= state.concurrency, do: state

  defp dispatch(state) do
    case Enum.find_index(state.waiting, fn {chat, _, _} ->
           not MapSet.member?(state.chats, chat)
         end) do
      nil ->
        state

      index ->
        {{chat, work, reply_to}, waiting} = List.pop_at(state.waiting, index)
        task = Task.Supervisor.async_nolink(state.supervisor, work)
        timer = Process.send_after(self(), {:timeout, task.ref}, state.timeout)
        job = %{chat: chat, reply_to: reply_to, pid: task.pid, timer: timer}

        dispatch(%{
          state
          | waiting: waiting,
            active: Map.put(state.active, task.ref, job),
            chats: MapSet.put(state.chats, chat)
        })
    end
  end

  defp finish(state, ref, result) do
    case Map.pop(state.active, ref) do
      {nil, _} ->
        state

      {job, active} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(job.timer)
        respond(job.reply_to, result)
        dispatch(%{state | active: active, chats: MapSet.delete(state.chats, job.chat)})
    end
  end

  defp respond(nil, _result), do: :ok
  defp respond(from, result), do: GenServer.reply(from, result)
end
