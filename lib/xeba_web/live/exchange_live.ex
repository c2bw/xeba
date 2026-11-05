defmodule XebaWeb.ExchangeLive do
  use XebaWeb, :live_view

  alias Xeba.Conversations
  alias Xeba.Telegram.Poller
  alias Xeba.Telegram.Prompt

  @dashboard_refresh_interval 100
  @token_usage_refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Conversations.subscribe()
      Poller.subscribe_connection_events()
      schedule_token_usage_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Telegram AI Console")
     |> assign(:selected_chat_id, nil)
     |> assign(:bot_name, configured_bot_name())
     |> assign(:chats, [])
     |> assign(:chat_names, %{})
     |> assign(:context_window, nil)
     |> assign(:context_preview, [])
     |> assign_saved_prompt("")
     |> assign(:pending_refresh, MapSet.new())
     |> assign(:refresh_timer, nil)
     |> assign(:connection_events, Poller.connection_events())
     |> assign(:gateway_status, Poller.connection_status())
     |> assign(:exchange_count, 0)
     |> assign(:token_usage, %{minute: 0, hour: 0, day: 0})
     |> assign(:replace_form, to_form(%{"from" => "", "to" => ""}, as: :replace))
     |> assign(:replace_preview, nil)
     |> assign(:replace_undo, Conversations.latest_undoable_database_text_replacement())
     |> assign(:chat_query, "")
     |> assign(:chat_filter_form, to_form(%{"query" => ""}, as: :chat_filter))
     |> stream(:exchanges, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected_chat_id = parse_chat_id(params["chat_id"])

    if Map.has_key?(params, "chat_id") and is_nil(selected_chat_id) do
      {:noreply, socket |> put_flash(:error, "Invalid chat ID.") |> redirect(to: ~p"/")}
    else
      load_chat_params(selected_chat_id, socket)
    end
  end

  defp load_chat_params(selected_chat_id, socket) do
    exchanges = list_exchanges(selected_chat_id)
    context_window = context_window(selected_chat_id)
    context_preview = context_preview(selected_chat_id, socket.assigns.bot_name)

    {:noreply,
     socket
     |> assign(:selected_chat_id, selected_chat_id)
     |> assign_chats()
     |> assign(:context_window, context_window)
     |> assign(:context_preview, context_preview)
     |> assign_saved_prompt(prompt_template(selected_chat_id))
     |> assign(:exchange_count, length(exchanges))
     |> assign(:token_usage, Conversations.rolling_token_usage())
     |> stream(:exchanges, exchanges, reset: true)}
  end

  @impl true
  def handle_info({:exchange_updated, exchange}, socket) do
    areas =
      if is_nil(socket.assigns.selected_chat_id) or
           socket.assigns.selected_chat_id == exchange.chat_id,
         do: [:chats, :usage, :exchanges],
         else: [:chats, :usage]

    {:noreply, queue_dashboard_refresh(socket, areas)}
  end

  def handle_info(
        {:refresh_dashboard, token},
        %{assigns: %{refresh_timer: {_timer, token}}} = socket
      ) do
    pending = socket.assigns.pending_refresh
    socket = clear_dashboard_refresh(socket)
    socket = if MapSet.member?(pending, :chats), do: assign_chats(socket), else: socket

    socket =
      if MapSet.member?(pending, :usage),
        do: assign(socket, :token_usage, Conversations.rolling_token_usage()),
        else: socket

    socket =
      if MapSet.member?(pending, :exchanges), do: assign_visible_exchanges(socket), else: socket

    {:noreply, socket}
  end

  def handle_info({:refresh_dashboard, _stale_token}, socket), do: {:noreply, socket}

  def handle_info({:database_text_replaced, _from, _to}, socket) do
    {:noreply, reload_visible_exchanges(socket)}
  end

  def handle_info({:chat_updated, _chat}, socket) do
    {:noreply, queue_dashboard_refresh(socket, [:chats])}
  end

  def handle_info(:refresh_token_usage, socket) do
    schedule_token_usage_refresh()

    {:noreply,
     socket
     |> assign(:token_usage, Conversations.rolling_token_usage())
     |> assign(:gateway_status, Poller.connection_status())}
  end

  def handle_info({:autonomous_setting_updated, setting}, socket) do
    if socket.assigns.selected_chat_id == setting.chat_id do
      prompt = setting.system_prompt || Prompt.default_template()

      socket =
        socket
        |> assign(:context_window, setting.context_window)
        |> assign(:context_preview, context_preview(setting.chat_id, socket.assigns.bot_name))

      socket =
        if socket.assigns.system_prompt_dirty? and
             socket.assigns.system_prompt_form.params["prompt"] != prompt,
           do: assign(socket, :system_prompt_saved, prompt),
           else: assign_saved_prompt(socket, prompt)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:exiron_connection_event, _event}, socket) do
    {:noreply,
     socket
     |> assign(:connection_events, Poller.connection_events())
     |> assign(:gateway_status, Poller.connection_status())}
  end

  @impl true
  def handle_event("validate_database_text", %{"replace" => params}, socket) do
    {:noreply,
     socket
     |> assign(:replace_form, to_form(params, as: :replace))
     |> assign(:replace_preview, nil)}
  end

  def handle_event("preview_database_text", %{"replace" => params}, socket) do
    from = Map.get(params, "from", "")
    to = Map.get(params, "to", "")

    case Conversations.preview_database_text_replacement(from) do
      {:ok, affected_rows} ->
        {:noreply,
         socket
         |> assign(:replace_form, to_form(params, as: :replace))
         |> assign(:replace_preview, %{
           from: String.trim(from),
           to: to,
           affected_rows: affected_rows
         })}

      {:error, :blank_source} ->
        {:noreply,
         socket
         |> put_flash(:error, "Enter the word you want to replace.")
         |> assign(:replace_form, to_form(params, as: :replace))}

      {:error, :delivery_in_progress} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Text replacement is blocked while a matching message is awaiting delivery."
         )
         |> assign(:replace_preview, nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not update the database text.")
         |> assign(:replace_form, to_form(params, as: :replace))}
    end
  end

  def handle_event("confirm_database_text", _params, %{assigns: %{replace_preview: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Preview the replacement before confirming it.")}
  end

  def handle_event("confirm_database_text", _params, socket) do
    %{from: from, to: to} = socket.assigns.replace_preview

    case Conversations.replace_database_text_with_undo(from, to) do
      {:ok, %{updated_rows: updated_rows, operation: operation}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Updated #{updated_rows} database rows. Undo is available below.")
         |> assign(:replace_form, to_form(%{"from" => "", "to" => ""}, as: :replace))
         |> assign(:replace_preview, nil)
         |> assign(:replace_undo, operation)
         |> reload_visible_exchanges()}

      {:error, :delivery_in_progress} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Text replacement is blocked while a matching message is awaiting delivery."
         )
         |> assign(:replace_preview, nil)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not update the database text.")
         |> assign(:replace_preview, nil)}
    end
  end

  def handle_event("cancel_database_text", _params, socket) do
    {:noreply, assign(socket, :replace_preview, nil)}
  end

  def handle_event("undo_database_text", _params, %{assigns: %{replace_undo: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "There is no replacement available to undo.")}
  end

  def handle_event("undo_database_text", _params, socket) do
    case Conversations.undo_database_text_replacement(socket.assigns.replace_undo) do
      {:ok, %{restored_rows: restored_rows}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Restored #{restored_rows} database rows.")
         |> assign(:replace_undo, Conversations.latest_undoable_database_text_replacement())
         |> reload_visible_exchanges()}

      {:error, reason} ->
        message =
          case reason do
            :restore_conflict ->
              "Undo canceled because the affected text was edited afterward."

            :legacy_snapshot ->
              "This replacement was made by an older version and cannot be safely undone."

            _ ->
              "Could not undo the database text replacement."
          end

        {:noreply,
         socket
         |> put_flash(:error, message)
         |> assign(:replace_undo, nil)}
    end
  end

  def handle_event("filter_conversations", %{"chat_filter" => %{"query" => query}}, socket) do
    {:noreply,
     socket
     |> assign(:chat_query, query)
     |> assign(:chat_filter_form, to_form(%{"query" => query}, as: :chat_filter))}
  end

  def handle_event("validate_system_prompt", %{"system_prompt" => params}, socket) do
    prompt = Map.get(params, "prompt", "")

    {:noreply,
     socket
     |> assign(:system_prompt_form, to_form(params, as: :system_prompt))
     |> assign(:system_prompt_dirty?, prompt != socket.assigns.system_prompt_saved)
     |> assign(:system_prompt_error, system_prompt_error(prompt))}
  end

  def handle_event("save_system_prompt", %{"system_prompt" => %{"prompt" => prompt}}, socket) do
    case Conversations.update_system_prompt(socket.assigns.selected_chat_id, prompt) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "System prompt saved for this chat.")
         |> refresh_system_prompt()}

      {:error, :blank_system_prompt} ->
        {:noreply,
         socket
         |> assign(:system_prompt_form, to_form(%{"prompt" => prompt}, as: :system_prompt))
         |> assign(:system_prompt_dirty?, prompt != socket.assigns.system_prompt_saved)
         |> assign(:system_prompt_error, "System prompt cannot be blank.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:system_prompt_form, to_form(%{"prompt" => prompt}, as: :system_prompt))
         |> assign(:system_prompt_dirty?, prompt != socket.assigns.system_prompt_saved)
         |> assign(:system_prompt_error, "System prompt must be between 1 and 20,000 characters.")}
    end
  end

  def handle_event("cancel_system_prompt", _params, socket) do
    {:noreply, refresh_system_prompt(socket)}
  end

  def handle_event("reset_system_prompt", _params, socket) do
    case Conversations.reset_system_prompt(socket.assigns.selected_chat_id) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "System prompt restored to the default.")
         |> refresh_system_prompt()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not reset the system prompt.")}
    end
  end

  defp list_exchanges(chat_id), do: Conversations.list_display_exchanges(chat_id)

  defp reload_visible_exchanges(socket) do
    socket
    |> clear_dashboard_refresh()
    |> assign_chats()
    |> assign(:token_usage, Conversations.rolling_token_usage())
    |> assign_visible_exchanges()
  end

  defp assign_visible_exchanges(socket) do
    exchanges = list_exchanges(socket.assigns.selected_chat_id)

    socket
    |> assign(:context_window, context_window(socket.assigns.selected_chat_id))
    |> assign(
      :context_preview,
      context_preview(socket.assigns.selected_chat_id, socket.assigns.bot_name)
    )
    |> assign(:exchange_count, length(exchanges))
    |> stream(:exchanges, exchanges, reset: true)
  end

  defp queue_dashboard_refresh(socket, areas) do
    socket =
      update(
        socket,
        :pending_refresh,
        &Enum.reduce(areas, &1, fn area, pending -> MapSet.put(pending, area) end)
      )

    if socket.assigns.refresh_timer do
      socket
    else
      token = make_ref()
      timer = Process.send_after(self(), {:refresh_dashboard, token}, @dashboard_refresh_interval)
      assign(socket, :refresh_timer, {timer, token})
    end
  end

  defp clear_dashboard_refresh(socket) do
    if socket.assigns.refresh_timer do
      {timer, _token} = socket.assigns.refresh_timer
      Process.cancel_timer(timer)
    end

    socket |> assign(:refresh_timer, nil) |> assign(:pending_refresh, MapSet.new())
  end

  defp assign_chats(socket) do
    chats = Conversations.list_chats()

    socket
    |> assign(:chats, chats)
    |> assign(:chat_names, Map.new(chats, &{&1.chat_id, &1.chat_name}))
  end

  defp schedule_token_usage_refresh do
    Process.send_after(self(), :refresh_token_usage, @token_usage_refresh_interval)
  end

  defp context_preview(nil, _bot_name), do: []

  defp context_preview(chat_id, bot_name) do
    setting = Conversations.autonomous_channel_setting(chat_id)

    chat_id
    |> Conversations.recent_history(setting.context_window)
    |> Prompt.preview(bot_name, setting.system_prompt || Prompt.default_template())
  end

  defp prompt_template(nil), do: ""
  defp prompt_template(chat_id), do: Conversations.system_prompt_template(chat_id)

  defp assign_saved_prompt(socket, prompt) do
    socket
    |> assign(:system_prompt_form, to_form(%{"prompt" => prompt}, as: :system_prompt))
    |> assign(:system_prompt_saved, prompt)
    |> assign(:system_prompt_dirty?, false)
    |> assign(:system_prompt_error, nil)
  end

  defp refresh_system_prompt(socket) do
    chat_id = socket.assigns.selected_chat_id

    socket
    |> assign_saved_prompt(prompt_template(chat_id))
    |> assign(:context_preview, context_preview(chat_id, socket.assigns.bot_name))
  end

  defp system_prompt_error(prompt) do
    cond do
      String.trim(prompt) == "" -> "System prompt cannot be blank."
      String.length(prompt) > 20_000 -> "System prompt cannot exceed 20,000 characters."
      true -> nil
    end
  end

  defp context_window(nil), do: nil

  defp context_window(chat_id) do
    chat_id
    |> Conversations.autonomous_channel_setting()
    |> Map.fetch!(:context_window)
  end

  defp configured_bot_name do
    Application.get_env(:xeba, Xeba.Telegram.Poller, [])
    |> Keyword.get(:bot_name, "xeba")
  end

  defp parse_chat_id(value), do: XebaWeb.ChatId.parse(value)

  @impl true
  def render(assigns), do: XebaWeb.ConsoleHTML.index(assigns)
end
