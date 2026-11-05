defmodule XebaWeb.ConsoleHTML do
  @moduledoc "Console markup and display formatting."
  use XebaWeb, :html

  import XebaWeb.ExchangeDisplay

  embed_templates "console_html/*"

  defp role_label(:system), do: "System"
  defp role_label(:user), do: "User"
  defp role_label(:assistant), do: "Assistant"

  defp role_classes(:system), do: "border-violet-400/20 bg-violet-400/10 text-violet-200"
  defp role_classes(:user), do: "border-cyan-400/20 bg-cyan-400/10 text-cyan-200"
  defp role_classes(:assistant), do: "border-emerald-400/20 bg-emerald-400/10 text-emerald-200"

  defp filter_chats(chats, query) do
    query = query |> String.trim() |> String.downcase()

    if query == "" do
      chats
    else
      Enum.filter(chats, fn chat ->
        "#{chat.chat_id} #{chat.chat_name || ""}"
        |> String.downcase()
        |> String.contains?(query)
      end)
    end
  end

  defp row_count_label(1), do: "1 row"
  defp row_count_label(count), do: "#{count} rows"

  defp status_label("completed"), do: "Delivered"
  defp status_label("observed"), do: "Observed"
  defp status_label("no_answer"), do: "No answer"
  defp status_label("reply_failed"), do: "Delivery failed"
  defp status_label("failed"), do: "AI failed"
  defp status_label(_), do: "Processing"

  defp status_classes("completed"), do: "border-emerald-400/20 bg-emerald-400/10 text-emerald-200"
  defp status_classes("observed"), do: "border-violet-400/20 bg-violet-400/10 text-violet-200"
  defp status_classes("no_answer"), do: "border-stone-400/20 bg-stone-400/10 text-stone-300"
  defp status_classes("reply_failed"), do: "border-amber-400/20 bg-amber-400/10 text-amber-200"
  defp status_classes("failed"), do: "border-rose-400/20 bg-rose-400/10 text-rose-200"
  defp status_classes(_), do: "border-cyan-400/20 bg-cyan-400/10 text-cyan-200"

  defp format_time(nil), do: "—"

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y · %H:%M:%S UTC")
  end

  defp format_latency(nil), do: "—"
  defp format_latency(milliseconds), do: "#{milliseconds} ms"

  defp format_tokens(nil), do: "—"
  defp format_tokens(tokens), do: Integer.to_string(tokens)

  defp format_quota(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(.{3})(?=.)/, "\\1,")
    |> String.reverse()
  end

  defp connection_event_label(%{status: :connected}), do: "Connected"
  defp connection_event_label(%{status: :disconnected}), do: "Disconnected"
  defp connection_event_label(_event), do: "Event"

  defp connection_event_classes(%{status: :connected}), do: "bg-emerald-400"
  defp connection_event_classes(%{status: :disconnected}), do: "bg-rose-400"
  defp connection_event_classes(_event), do: "bg-stone-400"

  defp gateway_status_label(:connected), do: "Online"
  defp gateway_status_label(:disconnected), do: "Offline"
  defp gateway_status_label(:connecting), do: "Connecting"
  defp gateway_status_label(:disabled), do: "Disabled"

  defp gateway_status_classes(:connected),
    do: "border-emerald-300/15 bg-emerald-300/[0.06] text-emerald-200"

  defp gateway_status_classes(:disconnected),
    do: "border-rose-300/20 bg-rose-300/[0.07] text-rose-200"

  defp gateway_status_classes(:connecting),
    do: "border-cyan-300/15 bg-cyan-300/[0.06] text-cyan-200"

  defp gateway_status_classes(:disabled),
    do: "border-stone-300/10 bg-white/[0.04] text-stone-400"

  defp gateway_dot_classes(:connected), do: "bg-emerald-400"
  defp gateway_dot_classes(:disconnected), do: "bg-rose-400"
  defp gateway_dot_classes(:connecting), do: "animate-pulse bg-cyan-300"
  defp gateway_dot_classes(:disabled), do: "bg-stone-600"
end
