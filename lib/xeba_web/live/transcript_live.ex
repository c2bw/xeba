defmodule XebaWeb.TranscriptLive do
  use XebaWeb, :live_view

  import XebaWeb.ExchangeDisplay

  alias Xeba.Conversations

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Conversations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Chat Transcript")
     |> assign(:chat_id, nil)
     |> assign(:chat_name, nil)
     |> assign(:selected_day, nil)
     |> assign(:date_map, [])
     |> assign(:older_dates?, false)
     |> assign(:page, 1)
     |> assign(:pages, 1)
     |> stream_configure(:transcript_events, dom_id: & &1.id)
     |> stream(:transcript_events, [])
     |> stream_configure(:transcript_dates, dom_id: &"transcript-date-#{&1.day}")
     |> stream(:transcript_dates, [])
     |> assign(:day_groups, [])
     |> assign(:message_count, 0)
     |> assign(:bot_message_count, 0)
     |> assign(:total_tokens, 0)}
  end

  @impl true
  def handle_params(%{"chat_id" => chat_id} = params, _uri, socket) do
    case parse_chat_id(chat_id) do
      nil -> {:noreply, socket |> put_flash(:error, "Invalid chat ID.") |> redirect(to: ~p"/")}
      id -> load_chat_params(id, params, socket)
    end
  end

  defp load_chat_params(chat_id, params, socket) do
    selected_day = parse_day(params["day"])

    {:noreply, load_transcript(socket, chat_id, selected_day, parse_page(params["page"]))}
  end

  @impl true
  def handle_info(
        {:exchange_updated, %{chat_id: chat_id}},
        %{assigns: %{chat_id: chat_id}} = socket
      ) do
    {:noreply, load_transcript(socket, chat_id, socket.assigns.selected_day)}
  end

  def handle_info({:exchange_updated, _exchange}, socket), do: {:noreply, socket}

  def handle_info(
        {:chat_updated, %{chat_id: chat_id, name: name}},
        %{assigns: %{chat_id: chat_id}} = socket
      ) do
    {:noreply, assign(socket, :chat_name, name)}
  end

  def handle_info({:chat_updated, _chat}, socket), do: {:noreply, socket}

  def handle_info({:database_text_replaced, _from, _to}, socket) do
    {:noreply, load_transcript(socket, socket.assigns.chat_id, socket.assigns.selected_day)}
  end

  def handle_info({:autonomous_setting_updated, _setting}, socket), do: {:noreply, socket}

  defp load_transcript(socket, chat_id, selected_day),
    do: load_transcript(socket, chat_id, selected_day, socket.assigns.page)

  defp load_transcript(socket, nil, _selected_day, _page) do
    socket
    |> assign(:chat_id, nil)
    |> assign(:chat_name, nil)
    |> assign(:selected_day, nil)
    |> assign(:date_map, [])
    |> assign(:older_dates?, false)
    |> assign(:page, 1)
    |> assign(:pages, 1)
    |> assign(:day_groups, [])
    |> assign(:message_count, 0)
    |> assign(:bot_message_count, 0)
    |> assign(:total_tokens, 0)
    |> stream(:transcript_events, [], reset: true)
    |> stream(:transcript_dates, [], reset: true)
  end

  defp load_transcript(socket, chat_id, selected_day, requested_page) do
    calendar = Conversations.transcript_calendar(chat_id, selected_day)

    calendar =
      if calendar.days == [] and selected_day,
        do: Conversations.transcript_calendar(chat_id),
        else: calendar

    selected_day =
      case calendar.days do
        [latest | _] -> latest.day
        [] -> nil
      end

    result =
      if selected_day,
        do: Conversations.transcript_page(chat_id, selected_day, requested_page),
        else: %{exchanges: [], page: 1, pages: 1}

    events =
      result.exchanges |> Enum.flat_map(&exchange_events/1) |> Enum.sort_by(&{&1.at, &1.sequence})

    dates =
      Enum.map(Enum.reverse(calendar.days), fn entry ->
        Map.merge(entry, %{param: Date.to_iso8601(entry.day), label: day_label(entry.day)})
      end)

    socket
    |> assign(:chat_id, chat_id)
    |> assign(:chat_name, Conversations.chat_name(chat_id))
    |> assign(:selected_day, selected_day)
    |> assign(:date_map, dates)
    |> assign(:older_dates?, calendar.older?)
    |> assign(:page, result.page)
    |> assign(:pages, result.pages)
    |> assign(:day_groups, if(events == [], do: [], else: [{selected_day, []}]))
    |> assign(:message_count, length(events))
    |> assign(:bot_message_count, Enum.count(events, &(&1.role == :assistant)))
    |> assign(:total_tokens, events |> Enum.map(&(&1.total_tokens || 0)) |> Enum.sum())
    |> stream(:transcript_events, events, reset: true)
    |> stream(:transcript_dates, dates, reset: true)
  end

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_page(_value), do: 1

  defp exchange_events(exchange) do
    [
      user_event(exchange),
      assistant_event(exchange)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp user_event(%{msgtype: "autonomous"}), do: nil

  defp user_event(exchange) do
    text = request_text(exchange)

    build_event(exchange, :user, text, sender_name(exchange), 0)
  end

  defp assistant_event(%{response_text: response_text} = exchange)
       when is_binary(response_text) and response_text != "" do
    build_event(exchange, :assistant, response_text, "Xeba", 1)
  end

  defp assistant_event(_exchange), do: nil

  defp build_event(exchange, role, text, sender, sequence) do
    local_at = local_datetime(exchange.inserted_at)

    %{
      id: "transcript-message-#{exchange.id}-#{role}",
      role: role,
      sender: sender,
      text: text,
      sticker_id: exchange.sticker_id,
      sticker: role == :user and sticker_request?(exchange),
      sticker_media: if(role == :user, do: sticker_media(exchange), else: nil),
      at: local_at,
      day: DateTime.to_date(local_at),
      total_tokens: event_tokens(exchange, role),
      sequence: {exchange.id, sequence}
    }
  end

  defp event_tokens(exchange, :assistant), do: exchange.total_tokens
  defp event_tokens(_exchange, _role), do: nil

  defp local_datetime(nil), do: local_datetime(DateTime.utc_now())

  defp local_datetime(datetime) do
    DateTime.add(datetime, rome_offset_seconds(datetime), :second)
  end

  defp rome_offset_seconds(datetime) do
    year = datetime.year
    dst_start = last_sunday_at_utc(year, 3, 1)
    dst_end = last_sunday_at_utc(year, 10, 1)

    if DateTime.compare(datetime, dst_start) != :lt and DateTime.compare(datetime, dst_end) == :lt do
      2 * 60 * 60
    else
      60 * 60
    end
  end

  defp last_sunday_at_utc(year, month, hour) do
    last_day = Date.days_in_month(Date.new!(year, month, 1))

    date =
      Enum.find(last_day..(last_day - 6)//-1, fn day ->
        Date.day_of_week(Date.new!(year, month, day)) == 7
      end)
      |> then(&Date.new!(year, month, &1))

    DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp parse_chat_id(value), do: XebaWeb.ChatId.parse(value)

  defp parse_day(day) when is_binary(day) do
    case Date.from_iso8601(day) do
      {:ok, %Date{year: year} = date} when year in 1..9999 -> date
      _ -> nil
    end
  end

  defp parse_day(_day), do: nil

  defp day_label(day), do: Calendar.strftime(day, "%b %d, %Y")

  defp time_label(datetime), do: Calendar.strftime(datetime, "%H:%M")

  defp count_label(1, singular, _plural), do: "1 #{singular}"
  defp count_label(count, _singular, plural), do: "#{count} #{plural}"

  defp date_link_classes(selected?, extra) do
    [
      "flex items-center justify-between rounded-lg px-2.5 py-2 text-left text-xs transition",
      selected? && "border border-cyan-300/20 bg-cyan-300/10 text-cyan-100",
      not selected? &&
        "border border-transparent text-stone-500 hover:bg-white/[0.04] hover:text-stone-200",
      extra
    ]
  end

  defp bubble_classes(:assistant) do
    "ml-auto border-emerald-300/20 bg-emerald-300/[0.08] text-stone-100"
  end

  defp bubble_classes(:user), do: "mr-auto border-cyan-300/15 bg-white/[0.045] text-stone-100"

  defp meta_classes(:assistant), do: "justify-end text-emerald-100/80"
  defp meta_classes(:user), do: "justify-start text-cyan-100/80"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="relative isolate overflow-hidden">
        <header class="mx-auto flex max-w-6xl flex-wrap items-center justify-end gap-2 px-3 pb-3 pt-5 sm:px-5 lg:px-6">
          <div class="mr-auto flex items-center gap-2.5">
            <div class="grid size-8 place-items-center rounded-xl border border-cyan-300/20 bg-cyan-300/10 shadow-[0_0_30px_rgba(34,211,238,0.1)]">
              <.icon name="hero-chat-bubble-left-right" class="size-4 text-cyan-200" />
            </div>
            <div>
              <p class="text-sm font-semibold tracking-wide text-white">Xeba transcript</p>
              <p id="transcript-chat-heading" class="text-xs text-stone-500">
                <%= if @chat_name do %>
                  <span class="font-medium text-stone-300">{@chat_name}</span>
                  <span class="mx-1 text-stone-700">/</span>
                  <span class="font-mono">chat:{@chat_id}</span>
                <% else %>
                  Chat {@chat_id}
                <% end %>
              </p>
            </div>
          </div>

          <.link
            id="transcript-console-link"
            navigate={~p"/chats/#{@chat_id}"}
            class="inline-flex items-center gap-2 rounded-lg border border-white/10 bg-white/[0.04] px-3 py-2 text-xs font-semibold text-stone-200 transition hover:-translate-y-0.5 hover:bg-white/[0.08]"
          >
            <.icon name="hero-command-line" class="size-4" /> Console view
          </.link>
          <.link
            id="transcript-sticker-bank-link"
            navigate={~p"/chats/#{@chat_id}/stickers"}
            class="inline-flex items-center gap-2 rounded-lg border border-cyan-300/15 bg-cyan-300/[0.05] px-3 py-2 text-xs font-semibold text-cyan-100 transition hover:-translate-y-0.5 hover:bg-cyan-300/10"
          >
            <.icon name="hero-sparkles" class="size-4" /> Stickers
          </.link>
        </header>

        <main class="mx-auto max-w-6xl px-3 pb-12 sm:px-5 lg:px-6">
          <div class="flex flex-wrap items-end justify-between gap-3 border-b border-white/10 pb-4">
            <div>
              <h1 class="text-xl font-semibold text-white sm:text-2xl">
                <%= if @chat_name do %>
                  <span id="transcript-chat-name">{@chat_name}</span>
                  <span class="ml-2 font-mono text-xs font-normal text-stone-500">
                    chat:{@chat_id}
                  </span>
                <% else %>
                  Chat {@chat_id}
                <% end %>
              </h1>
              <p class="mt-1 text-xs text-stone-500">
                Conversation grouped by Europe/Rome calendar day.
              </p>
            </div>
            <div
              id="transcript-message-count"
              class="flex flex-wrap items-center gap-2 rounded-lg border border-white/10 bg-white/[0.04] px-3 py-2 text-xs text-stone-400"
            >
              <span>{count_label(@message_count, "message", "messages")}</span>
              <span class="size-1 rounded-full bg-stone-600"></span>
              <span>{count_label(@bot_message_count, "bot message", "bot messages")}</span>
              <span class="size-1 rounded-full bg-stone-600"></span>
              <span>{@total_tokens} tokens</span>
            </div>
          </div>

          <section id="transcript" class="mt-4 grid gap-4 lg:grid-cols-[13rem_minmax(0,1fr)]">
            <div
              :if={@day_groups == []}
              id="transcript-empty"
              class="grid min-h-64 place-items-center rounded-xl border border-dashed border-white/10 bg-white/[0.025] p-8 text-center lg:col-span-2"
            >
              <div>
                <div class="mx-auto grid size-12 place-items-center rounded-2xl bg-white/5">
                  <.icon name="hero-chat-bubble-left-ellipsis" class="size-6 text-stone-500" />
                </div>
                <p class="mt-4 font-medium text-stone-300">No conversation yet</p>
                <p class="mt-2 text-sm text-stone-600">Messages for this chat will appear here.</p>
              </div>
            </div>

            <aside
              :if={@date_map != []}
              id="transcript-date-map"
              class="lg:sticky lg:top-16 lg:self-start"
            >
              <div class="rounded-xl border border-white/10 bg-white/[0.025] p-2">
                <div class="px-2 pb-2 pt-1">
                  <p class="text-xs font-semibold uppercase tracking-widest text-stone-500">
                    Date map
                  </p>
                </div>
                <nav
                  id="transcript-date-list"
                  phx-update="stream"
                  class="flex gap-1 overflow-x-auto pb-1 lg:block lg:space-y-1 lg:overflow-visible lg:pb-0"
                >
                  <.link
                    :for={{id, date_entry} <- @streams.transcript_dates}
                    id={id}
                    patch={~p"/chats/#{@chat_id}/transcript?day=#{date_entry.param}"}
                    class={
                      date_link_classes(
                        @selected_day == date_entry.day,
                        "w-auto shrink-0 lg:w-full"
                      )
                    }
                  >
                    <span>{date_entry.label}</span>
                    <span class="rounded-full bg-white/5 px-2 py-0.5 text-xs text-stone-500">
                      {date_entry.count}
                    </span>
                  </.link>
                </nav>
                <div class="mt-2 flex justify-between gap-2 px-2 text-xs text-cyan-200">
                  <.link
                    :if={@older_dates?}
                    id="transcript-older-dates"
                    patch={
                      ~p"/chats/#{@chat_id}/transcript?day=#{Date.to_iso8601(Date.add(hd(@date_map).day, -1))}"
                    }
                  >Older dates</.link>
                  <.link id="transcript-latest-date" patch={~p"/chats/#{@chat_id}/transcript"}>Latest</.link>
                </div>
              </div>
            </aside>

            <div :if={@day_groups != []} class="space-y-4">
              <div
                :for={{day, _events} <- @day_groups}
                id={"transcript-day-#{day}"}
                class="rounded-xl border border-white/10 bg-white/[0.025] p-4 shadow-xl shadow-black/10"
              >
                <div class="flex flex-wrap items-center justify-between gap-3 border-b border-white/10 pb-4">
                  <div class="flex items-center gap-3">
                    <div class="grid size-9 place-items-center rounded-2xl border border-white/10 bg-white/[0.04]">
                      <.icon name="hero-calendar-days" class="size-4 text-cyan-200" />
                    </div>
                    <h2
                      id={"transcript-day-#{day}-heading"}
                      class="text-sm font-semibold uppercase tracking-wide text-stone-200"
                    >
                      {day_label(day)}
                    </h2>
                  </div>
                  <span
                    id={"transcript-day-#{day}-count"}
                    class="rounded-full border border-white/10 bg-black/10 px-2.5 py-1 text-xs text-stone-500"
                  >
                    {count_label(@message_count, "message", "messages")}
                  </span>
                </div>

                <div id={"transcript-day-#{day}-messages"} phx-update="stream" class="mt-4 space-y-3">
                  <article
                    :for={{id, event} <- @streams.transcript_events}
                    id={id}
                    class={[
                      "max-w-[min(44rem,94%)] rounded-xl border px-4 py-3 shadow-xl shadow-black/10 transition duration-300 hover:-translate-y-0.5",
                      bubble_classes(event.role)
                    ]}
                  >
                    <div class={["mb-2 flex items-center gap-2 text-xs", meta_classes(event.role)]}>
                      <span class="font-semibold">{event.sender}</span>
                      <span class="size-1 rounded-full bg-current opacity-40"></span>
                      <time>{time_label(event.at)}</time>
                    </div>
                    <div
                      :if={event.sticker}
                      class="inline-flex max-w-full flex-col items-start gap-2 rounded-2xl border border-cyan-300/15 bg-cyan-300/[0.07] px-3 py-2 text-sm font-semibold text-cyan-100"
                    >
                      <img
                        :if={event.sticker_media && event.sticker_media.type == :image}
                        id={"#{event.id}-sticker"}
                        src={event.sticker_media.src}
                        loading="lazy"
                        alt={event.text}
                        class="max-h-44 w-auto rounded-xl object-contain"
                      />
                      <video
                        :if={event.sticker_media && event.sticker_media.type == :video}
                        id={"#{event.id}-sticker"}
                        preload="none"
                        autoplay
                        loop
                        muted
                        playsinline
                        class="max-h-44 w-auto rounded-xl object-contain"
                      >
                        <source src={event.sticker_media.src} type="video/webm" />
                      </video>
                      <span class="inline-flex items-center gap-2">
                        <.icon name="hero-sparkles" class="size-4" />
                        <span>{event.text}</span>
                      </span>
                      <span
                        :if={
                          event.sticker_media && event.sticker_media.type == :unsupported_animation
                        }
                        id={"#{event.id}-animated-sticker-note"}
                        class="text-xs font-medium text-cyan-100/70"
                      >
                        animated sticker
                      </span>
                      <span
                        :if={sticker_id(event)}
                        id={"#{event.id}-sticker-id"}
                        class="max-w-full truncate text-[0.65rem] font-normal text-cyan-100/60"
                      >
                        <span class="font-semibold uppercase tracking-widest text-cyan-100/45">
                          Sticker ID
                        </span>
                        <span class="font-mono">{sticker_id(event)}</span>
                      </span>
                    </div>
                    <p
                      :if={!event.sticker}
                      class="whitespace-pre-line break-words text-sm leading-6"
                    >
                      {event.text}
                    </p>
                  </article>
                </div>
              </div>
            </div>
          </section>
          <nav
            :if={@pages > 1}
            id="transcript-pagination"
            class="mt-4 flex items-center justify-between text-sm text-cyan-200"
          >
            <.link
              :if={@page > 1}
              id="transcript-previous-page"
              patch={
                ~p"/chats/#{@chat_id}/transcript?day=#{Date.to_iso8601(@selected_day)}&page=#{@page - 1}"
              }
            >Previous</.link>
            <span id="transcript-page-number">Page {@page} of {@pages}</span>
            <.link
              :if={@page < @pages}
              id="transcript-next-page"
              patch={
                ~p"/chats/#{@chat_id}/transcript?day=#{Date.to_iso8601(@selected_day)}&page=#{@page + 1}"
              }
            >Next</.link>
          </nav>
        </main>
      </div>
    </Layouts.app>
    """
  end
end
