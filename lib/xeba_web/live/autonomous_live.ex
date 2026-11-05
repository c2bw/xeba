defmodule XebaWeb.AutonomousLive do
  use XebaWeb, :live_view

  alias Xeba.Conversations
  alias Xeba.Telegram.Poller

  @tick_ms :timer.seconds(1)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Conversations.subscribe()
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok,
     socket
     |> assign(:page_title, "Autonomous Messages")
     |> assign(:settings_forms, %{})
     |> stream_configure(:channels, dom_id: &"autonomous-channel-#{&1.chat_id}")
     |> assign_channels()}
  end

  @impl true
  def handle_event(event, params, socket)
      when event in [
             "toggle-autonomous",
             "send-autonomous-now",
             "validate-settings",
             "save-settings"
           ] do
    chat_id = XebaWeb.ChatId.parse(params["chat-id"])

    if is_integer(chat_id) and Map.has_key?(socket.assigns.channels, chat_id) and
         Conversations.chat_exists?(chat_id) do
      handle_channel_event(event, Map.put(params, "chat-id", chat_id), socket)
    else
      {:noreply, put_flash(socket, :error, "This chat is not available.")}
    end
  end

  defp handle_channel_event("toggle-autonomous", %{"chat-id" => chat_id}, socket) do
    channel = Map.fetch!(socket.assigns.channels, chat_id)
    enabled = not channel.enabled

    {:ok, _setting} = Conversations.set_autonomous_enabled(chat_id, enabled)
    Poller.set_autonomous_enabled(chat_id, enabled)

    {:noreply,
     socket
     |> put_flash(:info, "Autonomous messages #{if enabled, do: "enabled", else: "disabled"}.")
     |> assign_channels()}
  end

  defp handle_channel_event("send-autonomous-now", %{"chat-id" => chat_id}, socket) do
    socket =
      case Poller.send_autonomous_now(chat_id) do
        :ok ->
          put_flash(socket, :info, "Autonomous message queued and timer reset.")

        {:error, reason} ->
          message =
            case reason do
              :poller_not_running -> "The Telegram poller is not running."
              :poller_disabled -> "The Telegram poller is disabled. Check its configuration."
              :busy -> "The message queue is full. Please try again shortly."
              :queue_unavailable -> "The message queue is unavailable. Please try again shortly."
              :autonomy_disabled -> "Autonomous messages are disabled for this chat."
              _ -> "This chat is not available for autonomous messages."
            end

          put_flash(socket, :error, message)
      end

    {:noreply, assign_channels(socket)}
  end

  defp handle_channel_event(
         "validate-settings",
         %{"chat-id" => chat_id, "autonomous_channel_setting" => setting_params},
         socket
       ) do
    setting = Conversations.autonomous_channel_setting(chat_id)

    form =
      setting
      |> Conversations.change_autonomous_channel_setting(setting_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     socket
     |> put_settings_form(chat_id, form)
     |> assign_channels()}
  end

  defp handle_channel_event(
         "save-settings",
         %{"chat-id" => chat_id, "autonomous_channel_setting" => setting_params},
         socket
       ) do
    case Conversations.update_autonomous_channel_setting(chat_id, setting_params) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> clear_settings_form(chat_id)
         |> put_flash(:info, "Autonomous configuration saved.")
         |> assign_channels()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_settings_form(chat_id, to_form(%{changeset | action: :insert}))
         |> assign_channels()}
    end
  end

  defp handle_channel_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid channel settings.")}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh_countdowns(socket)}
  end

  def handle_info({:exchange_updated, _exchange}, socket) do
    {:noreply, assign_channels(socket)}
  end

  def handle_info({:autonomous_setting_updated, _setting}, socket) do
    {:noreply, assign_channels(socket)}
  end

  def handle_info({:chat_updated, _chat}, socket) do
    {:noreply, assign_channels(socket)}
  end

  def handle_info({:database_text_replaced, _from, _to}, socket) do
    {:noreply, assign_channels(socket)}
  end

  defp refresh_countdowns(socket) do
    timers = Poller.timer_status()
    now = DateTime.utc_now()

    channels =
      Enum.map(socket.assigns.channels, fn {_id, channel} ->
        next_at = Map.get(timers, channel.chat_id)
        %{channel | next_at: next_at, remaining_seconds: remaining_seconds(next_at, now)}
      end)

    socket
    |> assign(:channels, Map.new(channels, &{&1.chat_id, &1}))
    |> stream(:channels, channels)
  end

  defp assign_channels(socket) do
    settings = Conversations.autonomous_settings()
    counts = Conversations.chat_message_counts()
    timers = Poller.timer_status()
    now = DateTime.utc_now()

    channels =
      Conversations.list_chats()
      |> Enum.map(fn chat ->
        message_count = Map.get(counts, chat.chat_id, 0)

        setting =
          Map.get(settings, chat.chat_id) ||
            %Xeba.Conversations.AutonomousChannelSetting{chat_id: chat.chat_id}

        %{
          chat_id: chat.chat_id,
          chat_name: chat.chat_name,
          setting: setting,
          form: Map.get(socket.assigns.settings_forms, chat.chat_id, setting_form(setting)),
          enabled: setting.enabled,
          next_at: Map.get(timers, chat.chat_id),
          remaining_seconds: remaining_seconds(Map.get(timers, chat.chat_id), now),
          message_count: message_count,
          messages_left: messages_left(message_count, setting.message_trigger)
        }
      end)

    socket
    |> assign(:channels, Map.new(channels, &{&1.chat_id, &1}))
    |> stream(:channels, channels, reset: true)
  end

  defp messages_left(count, trigger) do
    case rem(count, trigger) do
      0 -> trigger
      remainder -> trigger - remainder
    end
  end

  defp trigger_progress(messages_left, trigger) when trigger > 0 do
    ((trigger - messages_left) / trigger * 100)
    |> round()
    |> max(0)
    |> min(100)
  end

  defp setting_form(setting) do
    setting
    |> Conversations.change_autonomous_channel_setting()
    |> to_form()
  end

  defp put_settings_form(socket, chat_id, form) do
    update(socket, :settings_forms, &Map.put(&1, chat_id, form))
  end

  defp clear_settings_form(socket, chat_id) do
    update(socket, :settings_forms, &Map.delete(&1, chat_id))
  end

  defp remaining_seconds(nil, _now), do: nil
  defp remaining_seconds(next_at, now), do: max(DateTime.diff(next_at, now, :second), 0)

  def format_countdown(nil), do: "Scheduling…"

  def format_countdown(total_seconds) do
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    "#{pad(hours)}:#{pad(minutes)}:#{pad(seconds)}"
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="relative isolate overflow-hidden">
        <main class="mx-auto max-w-6xl px-3 pb-12 pt-5 sm:px-5 lg:px-6">
          <div class="flex flex-wrap items-end justify-between gap-3 border-b border-white/[0.08] pb-4">
            <div class="max-w-2xl">
              <p class="text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-emerald-300/70">
                Autonomous controls
              </p>
              <h1
                id="autonomous-heading"
                class="mt-1 text-xl font-semibold tracking-tight text-white sm:text-2xl"
              >
                Channel automation
              </h1>
              <p class="mt-1.5 text-xs leading-5 text-stone-500 sm:text-sm">
                Tune how much recent conversation Xeba reads and how many incoming messages should trigger an autonomous reply.
              </p>
            </div>
            <span class="inline-flex items-center gap-1.5 rounded-full border border-cyan-300/15 bg-cyan-300/[0.06] px-2.5 py-1 text-[0.65rem] font-medium text-cyan-200">
              <span class="size-1.5 animate-pulse rounded-full bg-cyan-300"></span> Live scheduler
            </span>
          </div>

          <div id="autonomous-channels" phx-update="stream" class="mt-4 grid gap-3">
            <div
              id="autonomous-empty"
              class="hidden rounded-xl border border-dashed border-white/10 bg-white/[0.025] p-8 text-center only:block"
            >
              <.icon name="hero-clock" class="mx-auto size-7 text-stone-600" />
              <p class="mt-4 text-sm text-stone-400">No Telegram channels have been observed yet.</p>
            </div>

            <article
              :for={{dom_id, channel} <- @streams.channels}
              id={dom_id}
              class={[
                "rounded-xl border p-4 shadow-xl shadow-black/10 transition sm:p-5",
                if(channel.enabled,
                  do: "border-white/10 bg-[#0b1714]/90",
                  else: "border-stone-700/50 bg-stone-950/40 opacity-75"
                )
              ]}
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div class="flex items-center gap-3">
                    <span class={[
                      "size-2 rounded-full",
                      if(channel.enabled, do: "animate-pulse bg-emerald-400", else: "bg-stone-600")
                    ]}></span>
                    <h2 class="flex flex-wrap items-baseline gap-x-2 text-base font-semibold text-white">
                      <span :if={channel.chat_name} id={"autonomous-chat-name-#{channel.chat_id}"}>
                        {channel.chat_name}
                      </span>
                      <span class={[
                        "font-mono",
                        channel.chat_name && "text-xs font-normal text-stone-500"
                      ]}>
                        chat:{channel.chat_id}
                      </span>
                    </h2>
                  </div>
                  <p class="mt-2 text-xs text-stone-500">
                    {if channel.enabled,
                      do: "Autonomous messages active",
                      else: "Autonomous messages paused"}
                  </p>
                </div>

                <div class="flex flex-wrap items-center gap-2">
                  <button
                    id={"send-autonomous-now-#{channel.chat_id}"}
                    type="button"
                    phx-click="send-autonomous-now"
                    phx-value-chat-id={channel.chat_id}
                    phx-disable-with="Sending…"
                    disabled={not channel.enabled}
                    class={[
                      "inline-flex items-center gap-2 rounded-xl border px-4 py-2 text-xs font-semibold transition active:scale-95 phx-click-loading:cursor-wait phx-click-loading:opacity-60",
                      channel.enabled &&
                        "border-cyan-300/15 bg-cyan-300/[0.06] text-cyan-100 hover:bg-cyan-300/10",
                      not channel.enabled &&
                        "cursor-not-allowed border-stone-700 bg-stone-800/40 text-stone-600"
                    ]}
                  >
                    <.icon name="hero-paper-airplane" class="size-4" /> Send now
                  </button>
                  <button
                    id={"toggle-autonomous-#{channel.chat_id}"}
                    type="button"
                    phx-click="toggle-autonomous"
                    phx-value-chat-id={channel.chat_id}
                    phx-disable-with="Updating…"
                    class={[
                      "rounded-xl border px-4 py-2 text-xs font-semibold transition active:scale-95 phx-click-loading:cursor-wait phx-click-loading:opacity-60",
                      if(channel.enabled,
                        do:
                          "border-rose-300/15 bg-rose-300/[0.06] text-rose-200 hover:bg-rose-300/10",
                        else:
                          "border-emerald-300/15 bg-emerald-300/[0.06] text-emerald-200 hover:bg-emerald-300/10"
                      )
                    ]}
                  >
                    {if channel.enabled, do: "Disable autonomous", else: "Enable autonomous"}
                  </button>
                </div>
              </div>

              <div class="mt-4 grid gap-2 sm:grid-cols-2">
                <section class="rounded-xl border border-white/[0.06] bg-black/10 p-4">
                  <div class="flex items-center gap-2 text-xs uppercase tracking-widest text-stone-500">
                    <.icon name="hero-clock" class="size-4 text-cyan-300/70" /> Next timer
                  </div>
                  <p
                    id={"timer-countdown-#{channel.chat_id}"}
                    class="mt-2 font-mono text-xl font-semibold tabular-nums text-cyan-100"
                  >
                    {if channel.enabled,
                      do: format_countdown(channel.remaining_seconds),
                      else: "Paused"}
                  </p>
                  <p class="mt-2 text-xs text-stone-600">Randomized between 5 and 7 hours</p>
                </section>

                <section class="rounded-xl border border-white/[0.06] bg-black/10 p-4">
                  <div class="flex items-center gap-2 text-xs uppercase tracking-widest text-stone-500">
                    <.icon name="hero-chat-bubble-left-ellipsis" class="size-4 text-emerald-300/70" />
                    Message trigger
                  </div>
                  <p
                    id={"messages-left-#{channel.chat_id}"}
                    class="mt-2 text-xl font-semibold text-emerald-100"
                  >
                    {channel.messages_left}
                    <span class="text-sm font-normal text-stone-500">messages left</span>
                  </p>
                  <p class="mt-2 text-xs text-stone-600">
                    Fires every {channel.setting.message_trigger} incoming messages; {channel.message_count} observed
                  </p>
                  <div class="mt-3 h-1 overflow-hidden rounded-full bg-white/[0.06]">
                    <div
                      class="h-full rounded-full bg-gradient-to-r from-emerald-400/60 to-cyan-300/80 transition-[width] duration-500"
                      style={
                        "width: #{trigger_progress(channel.messages_left, channel.setting.message_trigger)}%"
                      }
                    >
                    </div>
                  </div>
                </section>
              </div>

              <details
                id={"autonomous-settings-#{channel.chat_id}"}
                phx-mounted={JS.ignore_attributes("open")}
                class="group mt-3 rounded-xl border border-white/[0.06] bg-black/10"
              >
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 [&::-webkit-details-marker]:hidden">
                  <div class="flex items-center gap-2.5">
                    <span class="grid size-7 place-items-center rounded-lg bg-white/[0.04] text-stone-500">
                      <.icon name="hero-adjustments-horizontal" class="size-3.5" />
                    </span>
                    <div>
                      <h3 class="text-xs font-semibold text-stone-300">Channel configuration</h3>
                      <p class="text-[0.65rem] text-stone-600">
                        Context {channel.setting.context_window} · trigger {channel.setting.message_trigger}
                      </p>
                    </div>
                  </div>
                  <.icon
                    name="hero-chevron-down"
                    class="details-chevron size-4 text-stone-600 transition-transform"
                  />
                </summary>

                <.form
                  for={channel.form}
                  id={"autonomous-settings-form-#{channel.chat_id}"}
                  phx-change="validate-settings"
                  phx-submit="save-settings"
                  phx-value-chat-id={channel.chat_id}
                  class="border-t border-white/[0.06] p-4 transition phx-submit-loading:opacity-70"
                >
                  <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] sm:items-end">
                    <.input
                      field={channel.form[:context_window]}
                      id={"context-window-#{channel.chat_id}"}
                      type="number"
                      label="Context window"
                      min="1"
                      max="100"
                    />
                    <.input
                      field={channel.form[:message_trigger]}
                      id={"message-trigger-#{channel.chat_id}"}
                      type="number"
                      label="Message trigger"
                      min="1"
                      max="500"
                    />
                    <button
                      id={"save-autonomous-settings-#{channel.chat_id}"}
                      type="submit"
                      phx-disable-with="Saving…"
                      class="mb-2 inline-flex items-center justify-center gap-2 rounded-lg border border-emerald-300/15 bg-emerald-300/[0.06] px-4 py-2 text-xs font-semibold text-emerald-100 transition hover:bg-emerald-300/10 active:scale-95 phx-submit-loading:cursor-wait"
                    >
                      <.icon name="hero-check" class="size-3.5" /> Save
                    </button>
                  </div>
                </.form>
              </details>
            </article>
          </div>
        </main>
      </div>
    </Layouts.app>
    """
  end
end
