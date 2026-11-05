defmodule Xeba.Telegram.Poller do
  use GenServer

  require Logger

  alias Xeba.Conversations
  alias Xeba.Telegram.{Autonomous, Responder}
  import Xeba.Telegram.Processing, only: [timer_owner: 1]

  @recurring_autonomous_min_hours 5
  @recurring_autonomous_max_hours 7
  @autonomous_recovery_interval_ms :timer.seconds(30)
  @timer_status_table __MODULE__.TimerStatus
  @connection_events_table __MODULE__.ConnectionEvents
  @connection_status_table __MODULE__.ConnectionStatus
  @connection_events_topic "exiron_connection_events"
  @connection_event_limit 5

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def handle_message(message, server \\ __MODULE__, queue \\ Xeba.Telegram.JobQueue) do
    work = GenServer.call(server, {:prepare_message, message})
    Xeba.Telegram.JobQueue.run(message.chat_id, work, queue)
  end

  def managed_poller_child_spec do
    GenServer.call(__MODULE__, :managed_poller_child_spec)
  end

  def monitor_connection(connection_pid) when is_pid(connection_pid) do
    if poller_pid = Process.whereis(__MODULE__) do
      send(poller_pid, {:monitor_exiron_connection, connection_pid})
    end

    :ok
  end

  def notify_connection_event(status, reason \\ nil)
      when status in [:connected, :disconnected] do
    if pid = Process.whereis(__MODULE__) do
      send(pid, {:exiron_connection_status, status, reason, self()})
    end

    :ok
  end

  def subscribe_connection_events do
    Phoenix.PubSub.subscribe(Xeba.PubSub, @connection_events_topic)
  end

  def connection_events do
    case :ets.whereis(@connection_events_table) do
      :undefined ->
        []

      table ->
        table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {sequence, _event} -> sequence end, :desc)
        |> Enum.take(@connection_event_limit)
        |> Enum.map(fn {_sequence, event} -> event end)
    end
  rescue
    ArgumentError -> []
  end

  def connection_status do
    case :ets.whereis(@connection_status_table) do
      :undefined -> :disconnected
      table -> :ets.lookup_element(table, :status, 2, :connecting)
    end
  rescue
    ArgumentError -> :disconnected
  end

  def timer_status do
    case :ets.whereis(@timer_status_table) do
      :undefined ->
        %{}

      table ->
        table
        |> :ets.tab2list()
        |> Map.new()
    end
  rescue
    ArgumentError -> %{}
  end

  def set_autonomous_enabled(chat_id, enabled) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:set_autonomous_enabled, chat_id, enabled})
    end

    :ok
  end

  def send_autonomous_now(chat_id) do
    GenServer.call(__MODULE__, {:send_autonomous_now, chat_id})
  catch
    :exit, _reason -> {:error, :poller_not_running}
  end

  def validate_config(config) do
    required = [:base_url, :hook_token, :ai_api_key, :model]

    case Enum.find(required, &missing_config?(config[&1])) do
      nil ->
        :ok

      key ->
        {:error, "missing #{key} configuration"}
    end
  end

  defp missing_config?(nil), do: true
  defp missing_config?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_config?(_value), do: false

  @impl true
  def init(opts) do
    :ets.new(@timer_status_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    :ets.new(@connection_events_table, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true
    ])

    status_table =
      :ets.new(@connection_status_table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true
      ])

    :ets.insert(status_table, {:status, :connecting})

    config = Keyword.merge(Application.get_env(:xeba, __MODULE__, []), opts)

    if config[:enabled] == false do
      put_connection_status(:disabled)
      {:ok, %{enabled: false}}
    else
      case validate_config(config) do
        :ok ->
          exiron = config[:exiron_module] || Xeba.Telegram.Exiron
          llm = config[:llm_module] || Xeba.Telegram.LLM

          client =
            exiron.new(
              base_url: config[:base_url],
              token: config[:hook_token],
              client_id: client_id(config[:client_id]),
              listen: true
            )

          state =
            %{
              enabled: true,
              background_jobs: true,
              timer_owner: self(),
              client: client,
              exiron: exiron,
              llm: llm,
              model: config[:model],
              llm_options: [
                endpoint: config[:ai_endpoint],
                api_key: config[:ai_api_key]
              ],
              bot_name: config[:bot_name] || "xeba",
              autonomous_timers: %{},
              exiron_connection_pid: nil,
              exiron_connection_ref: nil
            }
            |> schedule_known_chats()

          send(self(), :resume_autonomous_deliveries)
          {:ok, state}

        {:error, reason} ->
          Logger.warning("Telegram poller disabled: #{reason}")
          put_connection_status(:disabled)
          {:ok, %{enabled: false}}
      end
    end
  end

  @impl true
  def handle_info(:resume_autonomous_deliveries, %{enabled: true} = state) do
    for id <- Autonomous.retryable_ids() do
      send(self(), {:retry_autonomous_delivery, id})
    end

    Process.send_after(
      timer_owner(state),
      :resume_autonomous_deliveries,
      @autonomous_recovery_interval_ms
    )

    {:noreply, state}
  end

  def handle_info({:retry_autonomous_delivery, id}, %{enabled: true} = state) do
    case Xeba.Repo.get(Xeba.Conversations.Exchange, id) do
      %{msgtype: "autonomous", status: status, chat_id: chat_id}
      when status in ["pending", "reply_failed"] ->
        if Conversations.autonomous_enabled?(chat_id) do
          snapshot = worker_state(state)
          work = fn -> Autonomous.retry(id, snapshot) end

          result =
            if Map.get(state, :background_jobs, false),
              do:
                Xeba.Telegram.JobQueue.submit(
                  chat_id,
                  work,
                  nil,
                  Map.get(state, :job_queue, Xeba.Telegram.JobQueue)
                ),
              else: work.()

          if match?({:error, _}, result) do
            Process.send_after(timer_owner(state), {:retry_autonomous_delivery, id}, 5_000)
          end
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(:resume_autonomous_deliveries, state), do: {:noreply, state}
  def handle_info({:retry_autonomous_delivery, _id}, state), do: {:noreply, state}

  def handle_info(:refresh_chat_names, %{enabled: true} = state) do
    snapshot = worker_state(state)

    Xeba.Telegram.JobQueue.submit(:chat_names, fn ->
      if function_exported?(snapshot.exiron, :status, 1) do
        case snapshot.exiron.status(snapshot.client) do
          {:ok, status} -> Conversations.remember_chat_names_from_status(status)
          {:error, _reason} -> :ok
        end
      end
    end)

    {:noreply, state}
  end

  def handle_info(:refresh_chat_names, state), do: {:noreply, state}

  def handle_info(
        {:exiron_connection_status, :connected, reason, connection_pid},
        %{enabled: true} = state
      ) do
    state = monitor_connection(state, connection_pid)
    record_connection_event(:connected, reason)
    {:noreply, state}
  end

  def handle_info(
        {:exiron_connection_status, :disconnected, reason, connection_pid},
        %{enabled: true} = state
      ) do
    if Map.get(state, :exiron_connection_pid) in [nil, connection_pid] do
      state = monitor_connection(state, connection_pid)
      record_connection_event(:disconnected, reason)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:exiron_connection_status, _status, _reason, _connection_pid}, state),
    do: {:noreply, state}

  def handle_info({:monitor_exiron_connection, connection_pid}, %{enabled: true} = state) do
    {:noreply, monitor_connection(state, connection_pid)}
  end

  def handle_info({:monitor_exiron_connection, _connection_pid}, state), do: {:noreply, state}

  def handle_info({:autonomous_message, chat_id}, %{enabled: true} = state) do
    if Conversations.autonomous_enabled?(chat_id), do: queue_autonomous(chat_id, state)
    {:noreply, state}
  end

  def handle_info({:recurring_autonomous_message, chat_id}, %{enabled: true} = state) do
    if Conversations.autonomous_enabled?(chat_id), do: queue_autonomous(chat_id, state)

    state =
      state
      |> update_in([:autonomous_timers], &Map.delete(&1, chat_id))
      |> schedule_recurring_autonomous_message(chat_id)

    {:noreply, state}
  end

  def handle_info({:follow_up_response, chat_id, prompt}, %{enabled: true} = state) do
    if Conversations.autonomous_enabled?(chat_id),
      do: queue_autonomous(chat_id, prompt, state, schedule_follow_up?: false)

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, connection_pid, reason},
        %{exiron_connection_ref: ref, exiron_connection_pid: connection_pid} = state
      ) do
    record_connection_event(:disconnected, reason)

    {:noreply, %{state | exiron_connection_pid: nil, exiron_connection_ref: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:set_autonomous_enabled, _chat_id, _enabled}, %{enabled: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:set_autonomous_enabled, chat_id, true}, state) do
    {:noreply, schedule_recurring_autonomous_message(state, chat_id)}
  end

  def handle_cast({:set_autonomous_enabled, chat_id, false}, state) do
    {:noreply, cancel_recurring_autonomous_message(state, chat_id)}
  end

  @impl true
  def handle_call({:send_autonomous_now, _chat_id}, _from, %{enabled: false} = state) do
    {:reply, {:error, :poller_disabled}, state}
  end

  def handle_call({:send_autonomous_now, chat_id}, _from, state) do
    cond do
      not is_integer(chat_id) or not Conversations.chat_exists?(chat_id) ->
        {:reply, {:error, :invalid_chat}, state}

      not Conversations.autonomous_enabled?(chat_id) ->
        {:reply, {:error, :autonomy_disabled}, state}

      true ->
        case queue_autonomous(chat_id, Map.put(state, :background_jobs, true)) do
          :ok ->
            state =
              state
              |> cancel_recurring_autonomous_message(chat_id)
              |> schedule_recurring_autonomous_message(chat_id)

            {:reply, :ok, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:prepare_message, message}, _from, %{enabled: true} = state) do
    state = schedule_recurring_autonomous_message(state, message.chat_id)
    snapshot = worker_state(state)
    {:reply, fn -> Responder.process(message, snapshot) end, state}
  end

  def handle_call(:managed_poller_child_spec, _from, %{enabled: true} = state) do
    poller_opts = [
      client: state.client,
      transport: :websocket,
      handler_concurrency: 4,
      handler_order_by_chat: true,
      handler: &handle_message/1,
      on_connect: fn ->
        notify_connection_event(:connected)

        if poller_pid = Process.whereis(__MODULE__) do
          send(poller_pid, :refresh_chat_names)
        end
      end,
      on_disconnect: fn reason -> notify_connection_event(:disconnected, reason) end
    ]

    child_spec = %{
      id: Xeba.Telegram.ExironConnection,
      start: {state.exiron, :start_poller, [poller_opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }

    {:reply, child_spec, state}
  end

  def handle_call(:managed_poller_child_spec, _from, state), do: {:reply, :ignore, state}

  defp record_connection_event(status, reason) do
    if connection_status() == status do
      :ok
    else
      event = %{
        id: System.unique_integer([:positive, :monotonic]),
        status: status,
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:second),
        detail: connection_event_detail(status, reason)
      }

      put_connection_status(status)

      case :ets.whereis(@connection_events_table) do
        :undefined ->
          :ok

        table ->
          :ets.insert(table, {event.id, event})
          trim_connection_events(table)

          Phoenix.PubSub.broadcast(
            Xeba.PubSub,
            @connection_events_topic,
            {:exiron_connection_event, event}
          )
      end

      :ok
    end
  end

  defp monitor_connection(state, connection_pid) do
    current_pid = Map.get(state, :exiron_connection_pid)
    current_ref = Map.get(state, :exiron_connection_ref)

    if current_pid == connection_pid and is_reference(current_ref) do
      state
    else
      if is_pid(current_pid) and current_pid != connection_pid and
           connection_status() != :disconnected do
        record_connection_event(:disconnected, :restarting)
      end

      if is_reference(current_ref) do
        Process.demonitor(current_ref, [:flush])
      end

      state
      |> Map.put(:exiron_connection_pid, connection_pid)
      |> Map.put(:exiron_connection_ref, Process.monitor(connection_pid))
    end
  end

  defp put_connection_status(status) do
    case :ets.whereis(@connection_status_table) do
      :undefined -> :ok
      table -> :ets.insert(table, {:status, status})
    end
  rescue
    ArgumentError -> :ok
  end

  defp trim_connection_events(table) do
    table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {sequence, _event} -> sequence end, :desc)
    |> Enum.drop(@connection_event_limit)
    |> Enum.each(fn {sequence, _event} -> :ets.delete(table, sequence) end)
  end

  defp connection_event_detail(:connected, _reason), do: "Polling started"
  defp connection_event_detail(:disconnected, :normal), do: "Polling stopped"
  defp connection_event_detail(:disconnected, :shutdown), do: "Polling shut down"

  defp connection_event_detail(:disconnected, %ExironClient.Error{} = error) do
    "#{humanize_reason(error.reason)}: #{error.message}"
  end

  defp connection_event_detail(:disconnected, reason) when is_atom(reason) do
    humanize_reason(reason)
  end

  defp connection_event_detail(:disconnected, reason), do: inspect(reason)

  defp humanize_reason(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp client_id(value) when is_binary(value) and value != "", do: value
  defp client_id(_value), do: "xeba"

  @doc false
  def recurring_autonomous_delay_ms do
    @recurring_autonomous_min_hours..@recurring_autonomous_max_hours
    |> Enum.random()
    |> :timer.hours()
  end

  defp schedule_known_chats(state) do
    Conversations.list_chats()
    |> Enum.reduce(state, fn chat, acc ->
      schedule_recurring_autonomous_message(acc, chat.chat_id)
    end)
  end

  defp schedule_recurring_autonomous_message(state, chat_id) when is_integer(chat_id) do
    if Map.has_key?(state.autonomous_timers, chat_id) or
         not Conversations.autonomous_enabled?(chat_id) do
      state
    else
      delay_ms = recurring_autonomous_delay_ms()

      timer_ref =
        Process.send_after(
          self(),
          {:recurring_autonomous_message, chat_id},
          delay_ms
        )

      timer = %{
        ref: timer_ref,
        next_at: DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
      }

      :ets.insert(@timer_status_table, {chat_id, timer.next_at})
      put_in(state, [:autonomous_timers, chat_id], timer)
    end
  end

  defp schedule_recurring_autonomous_message(state, _chat_id), do: state

  defp cancel_recurring_autonomous_message(state, chat_id) do
    :ets.delete(@timer_status_table, chat_id)

    case Map.pop(state.autonomous_timers, chat_id) do
      {nil, timers} ->
        %{state | autonomous_timers: timers}

      {%{ref: timer_ref}, timers} ->
        Process.cancel_timer(timer_ref)
        %{state | autonomous_timers: timers}
    end
  end

  defp queue_autonomous(chat_id, state) do
    queue_autonomous(chat_id, Autonomous.default_prompt(), state, schedule_follow_up?: true)
  end

  defp queue_autonomous(chat_id, prompt, state, opts) do
    if Map.get(state, :background_jobs, false) do
      snapshot = worker_state(state)

      result =
        Xeba.Telegram.JobQueue.submit(
          chat_id,
          fn ->
            if Conversations.autonomous_enabled?(chat_id),
              do: Autonomous.generate(chat_id, prompt, snapshot, opts)

            :ok
          end,
          nil,
          Map.get(state, :job_queue, Xeba.Telegram.JobQueue)
        )

      if match?({:error, _}, result),
        do: Logger.warning("Autonomous job admission failed: #{inspect(result)}")

      result
    else
      Autonomous.generate(chat_id, prompt, state, opts)
    end
  end

  defp worker_state(state) do
    Map.take(state, [
      :enabled,
      :client,
      :exiron,
      :llm,
      :model,
      :llm_options,
      :bot_name,
      :sticker_reply_delay_ms,
      :autonomous_retry_delay_ms,
      :timer_owner
    ])
  end
end
