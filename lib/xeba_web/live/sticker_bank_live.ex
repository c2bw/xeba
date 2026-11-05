defmodule XebaWeb.StickerBankLive do
  use XebaWeb, :live_view

  alias Xeba.Conversations

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sticker Bank")
     |> assign(:chat_id, nil)
     |> assign(:chat_name, nil)
     |> assign(:total, 0)
     |> assign(:matched, 0)
     |> assign(:page, 1)
     |> assign(:pages, 1)
     |> stream_configure(:stickers, dom_id: &"sticker-bank-item-#{&1.id}")
     |> stream(:stickers, [])
     |> assign(:filter_emoji, "")
     |> assign(:filter_form, to_form(%{"emoji" => ""}, as: :filter))}
  end

  @impl true
  def handle_params(%{"chat_id" => chat_id} = params, _uri, socket) do
    case parse_chat_id(chat_id) do
      nil -> {:noreply, socket |> put_flash(:error, "Invalid chat ID.") |> redirect(to: ~p"/")}
      id -> load_chat_params(id, params, socket)
    end
  end

  defp load_chat_params(chat_id, params, socket) do
    emoji = if is_binary(params["emoji"]), do: String.trim(params["emoji"]), else: ""

    page =
      case parse_integer(params["page"]) do
        {number, ""} when number > 0 -> number
        _ -> 1
      end

    result =
      if is_integer(chat_id),
        do: Conversations.sticker_page(chat_id, emoji, page),
        else: %{stickers: [], total: 0, matched: 0, page: 1, pages: 1}

    {:noreply,
     socket
     |> assign(:chat_id, chat_id)
     |> assign(:chat_name, Conversations.chat_name(chat_id))
     |> assign(:total, result.total)
     |> assign(:matched, result.matched)
     |> assign(:page, result.page)
     |> assign(:pages, result.pages)
     |> assign(:filter_emoji, emoji)
     |> assign(:filter_form, to_form(%{"emoji" => emoji}, as: :filter))
     |> stream(:stickers, result.stickers, reset: true)}
  end

  @impl true
  def handle_event("filter", %{"filter" => %{"emoji" => emoji}}, socket) do
    emoji = if is_binary(emoji), do: String.trim(emoji), else: ""

    {:noreply,
     push_patch(socket, to: ~p"/chats/#{socket.assigns.chat_id}/stickers?emoji=#{emoji}")}
  end

  defp parse_integer(value) when is_binary(value), do: Integer.parse(value)
  defp parse_integer(_value), do: :error

  defp parse_chat_id(value), do: XebaWeb.ChatId.parse(value)

  defp sticker_media(sticker) do
    case Conversations.sticker_media_type(sticker.data_prefix) do
      :image -> %{type: :image, src: ~p"/chats/#{sticker.chat_id}/stickers/#{sticker.id}/media"}
      :video -> %{type: :video, src: ~p"/chats/#{sticker.chat_id}/stickers/#{sticker.id}/media"}
      :unsupported_animation -> %{type: :unsupported_animation}
      nil -> nil
    end
  end

  defp sticker_label(%{emoji_list: emoji_list}) when is_list(emoji_list) and emoji_list != [] do
    Enum.join(emoji_list, " ")
  end

  defp sticker_label(%{emoji: emoji}) when is_binary(emoji) and emoji != "", do: emoji
  defp sticker_label(_sticker), do: "sticker"

  defp format_time(nil), do: "unknown"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%b %d, %Y %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="relative isolate overflow-hidden">
        <header class="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3 px-3 pb-3 pt-5 sm:px-5 lg:px-6">
          <div class="flex items-center gap-2.5">
            <div class="grid size-8 place-items-center rounded-xl border border-cyan-300/20 bg-cyan-300/10">
              <.icon name="hero-sparkles" class="size-4 text-cyan-200" />
            </div>
            <div>
              <p class="text-sm font-semibold tracking-wide text-white">Sticker bank</p>
              <p id="sticker-bank-chat-heading" class="text-xs text-stone-500">
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

          <div class="flex flex-wrap gap-2">
            <.link
              id="sticker-bank-console-link"
              navigate={~p"/chats/#{@chat_id}"}
              class="inline-flex items-center gap-2 rounded-lg border border-white/10 bg-white/[0.04] px-3 py-2 text-xs font-semibold text-stone-200 transition hover:-translate-y-0.5 hover:bg-white/[0.08]"
            >
              <.icon name="hero-command-line" class="size-4" /> Console
            </.link>
            <.link
              id="sticker-bank-transcript-link"
              navigate={~p"/chats/#{@chat_id}/transcript"}
              class="inline-flex items-center gap-2 rounded-lg border border-white/10 bg-white/[0.04] px-3 py-2 text-xs font-semibold text-stone-200 transition hover:-translate-y-0.5 hover:bg-white/[0.08]"
            >
              <.icon name="hero-chat-bubble-left-right" class="size-4" /> Transcript
            </.link>
          </div>
        </header>

        <main class="mx-auto max-w-6xl px-3 pb-12 sm:px-5 lg:px-6">
          <div class="flex flex-wrap items-end justify-between gap-3 border-b border-white/10 pb-4">
            <div>
              <h1 class="text-xl font-semibold text-white sm:text-2xl">
                <%= if @chat_name do %>
                  <span id="sticker-bank-chat-name">{@chat_name}</span>
                  <span class="ml-2 font-mono text-xs font-normal text-stone-500">
                    chat:{@chat_id}
                  </span>
                <% else %>
                  Chat {@chat_id}
                <% end %>
              </h1>
              <p class="mt-1 text-xs text-stone-500">
                Stickers observed in this chat, ready for future replies.
              </p>
            </div>
            <div
              id="sticker-bank-count"
              class="rounded-lg border border-white/10 bg-white/[0.04] px-3 py-2 text-xs text-stone-400"
            >
              {@total} stickers
            </div>
          </div>

          <.form
            for={@filter_form}
            id="sticker-bank-filter-form"
            phx-change="filter"
            class="mt-3 flex flex-col gap-2 rounded-xl border border-white/10 bg-white/[0.035] p-3 transition phx-change-loading:border-cyan-300/20 sm:flex-row sm:items-end"
          >
            <div class="min-w-0 flex-1">
              <.input
                field={@filter_form[:emoji]}
                id="sticker-bank-emoji-filter"
                type="text"
                label="Find by emoji"
                placeholder="🤣"
                phx-debounce="250"
              />
            </div>
            <div
              id="sticker-bank-filter-count"
              aria-live="polite"
              class="inline-flex items-center justify-center gap-2 rounded-xl border border-cyan-300/15 bg-cyan-300/[0.07] px-3 py-2 text-xs font-semibold text-cyan-100"
            >
              <.icon
                name="hero-arrow-path"
                class="hidden size-3.5 animate-spin phx-change-loading:block"
              />
              <span class="phx-change-loading:hidden">{@matched} matched</span>
              <span class="hidden phx-change-loading:inline">Filtering…</span>
            </div>
          </.form>

          <section id="sticker-bank" class="mt-4">
            <div
              :if={@total == 0}
              id="sticker-bank-empty"
              class="grid min-h-64 place-items-center rounded-xl border border-dashed border-white/10 bg-white/[0.025] p-8 text-center"
            >
              <div>
                <div class="mx-auto grid size-12 place-items-center rounded-2xl bg-white/5">
                  <.icon name="hero-sparkles" class="size-6 text-stone-500" />
                </div>
                <p class="mt-4 font-medium text-stone-300">No stickers banked yet</p>
                <p class="mt-2 text-sm text-stone-600">
                  Stickers will appear here after Xeba observes them in this chat.
                </p>
              </div>
            </div>

            <div
              :if={@total > 0 && @matched == 0}
              id="sticker-bank-filter-empty"
              class="grid min-h-52 place-items-center rounded-xl border border-dashed border-white/10 bg-white/[0.025] p-8 text-center"
            >
              <div>
                <div class="mx-auto grid size-12 place-items-center rounded-2xl bg-white/5">
                  <.icon name="hero-magnifying-glass" class="size-6 text-stone-500" />
                </div>
                <p class="mt-4 font-medium text-stone-300">No sticker matches</p>
              </div>
            </div>

            <div
              :if={@matched > 0}
              id="sticker-bank-grid"
              phx-update="stream"
              class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
            >
              <article
                :for={{id, sticker} <- @streams.stickers}
                id={id}
                class="rounded-xl border border-white/10 bg-white/[0.035] p-3 shadow-xl shadow-black/10 transition duration-300 hover:-translate-y-0.5 hover:border-cyan-300/20"
              >
                <div class="grid h-36 place-items-center rounded-lg border border-white/[0.06] bg-black/15 p-3">
                  <img
                    :if={sticker_media(sticker) && sticker_media(sticker).type == :image}
                    id={"sticker-bank-media-#{sticker.id}"}
                    src={sticker_media(sticker).src}
                    alt={sticker_label(sticker)}
                    loading="lazy"
                    class="max-h-28 w-auto object-contain"
                  />
                  <video
                    :if={sticker_media(sticker) && sticker_media(sticker).type == :video}
                    id={"sticker-bank-media-#{sticker.id}"}
                    autoplay
                    loop
                    muted
                    playsinline
                    class="max-h-28 w-auto object-contain"
                  >
                    <source src={sticker_media(sticker).src} type="video/webm" />
                  </video>
                  <div
                    :if={
                      !sticker_media(sticker) || sticker_media(sticker).type == :unsupported_animation
                    }
                    id={"sticker-bank-fallback-#{sticker.id}"}
                    class="grid size-24 place-items-center rounded-2xl border border-cyan-300/15 bg-cyan-300/[0.07] text-center text-xs font-semibold text-cyan-100"
                  >
                    animated sticker
                  </div>
                </div>

                <div class="mt-3 space-y-2">
                  <div class="flex items-center justify-between gap-3">
                    <span
                      id={"sticker-bank-emoji-#{sticker.id}"}
                      class="min-w-0 rounded-full border border-cyan-300/15 bg-cyan-300/[0.07] px-2 py-1 text-xs font-semibold text-cyan-100"
                    >
                      {sticker_label(sticker)}
                    </span>
                    <time class="text-[0.65rem] text-stone-600">
                      {format_time(sticker.last_seen_at)}
                    </time>
                  </div>
                  <div
                    id={"sticker-bank-id-#{sticker.id}"}
                    class="rounded-lg border border-white/10 bg-black/20 px-2 py-1.5"
                  >
                    <p class="mb-1 text-[0.6rem] font-semibold uppercase tracking-widest text-stone-600">
                      Unique file ID
                    </p>
                    <code
                      :if={sticker.file_unique_id}
                      id={"sticker-bank-unique-id-#{sticker.id}"}
                      class="block break-all font-mono text-[0.65rem] text-stone-300"
                    >
                      {sticker.file_unique_id}
                    </code>
                    <p :if={!sticker.file_unique_id} class="text-[0.65rem] text-stone-500">
                      Not available yet
                    </p>
                    <details id={"sticker-bank-file-id-#{sticker.id}"} class="mt-2">
                      <summary class="cursor-pointer text-[0.65rem] text-stone-400 transition hover:text-stone-200">
                        Telegram file ID
                      </summary>
                      <code class="mt-1 block break-all font-mono text-[0.65rem] text-stone-400">
                        {sticker.sticker_id}
                      </code>
                    </details>
                  </div>
                </div>
              </article>
            </div>
          </section>
          <nav
            :if={@pages > 1}
            id="sticker-bank-pagination"
            class="mt-4 flex items-center justify-between text-sm text-cyan-200"
          >
            <.link
              :if={@page > 1}
              id="sticker-bank-previous-page"
              patch={~p"/chats/#{@chat_id}/stickers?emoji=#{@filter_emoji}&page=#{@page - 1}"}
            >Previous</.link>
            <span id="sticker-bank-page-number">Page {@page} of {@pages}</span>
            <.link
              :if={@page < @pages}
              id="sticker-bank-next-page"
              patch={~p"/chats/#{@chat_id}/stickers?emoji=#{@filter_emoji}&page=#{@page + 1}"}
            >Next</.link>
          </nav>
        </main>
      </div>
    </Layouts.app>
    """
  end
end
