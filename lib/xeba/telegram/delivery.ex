defmodule Xeba.Telegram.Delivery do
  @moduledoc "Outbound text and sticker delivery with persistent checkpoints."

  import Xeba.Telegram.Processing, only: [update!: 2]

  alias Xeba.Conversations

  @sticker_response_roll 1
  @sticker_response_sides 2
  @sticker_reply_delay_ms :timer.seconds(3)

  @doc false
  def sticker_response?(roll \\ :rand.uniform(@sticker_response_sides))
  def sticker_response?(@sticker_response_roll), do: true
  def sticker_response?(_roll), do: false

  @doc false
  def sticker_response_plan(
        response_text,
        stickers,
        roll \\ :rand.uniform(@sticker_response_sides),
        picker \\ &Enum.random/1
      )

  def sticker_response_plan(response_text, stickers, roll, picker)
      when is_binary(response_text) and is_list(stickers) and is_function(picker, 1) do
    with true <- sticker_response?(roll),
         {text, emoji} <- trailing_emoji_split(response_text),
         false <- String.trim(text) == "",
         matching_stickers = Enum.filter(stickers, &sticker_matches_emoji?(&1, emoji)),
         false <- matching_stickers == [] do
      {:sticker, text, picker.(matching_stickers)}
    else
      _ -> :text
    end
  end

  def sticker_response_plan(_response_text, _stickers, _roll, _picker), do: :text

  def deliver(exchange, message, response_text, state, autonomous? \\ false) do
    exchange = ensure_delivery_plan(exchange, message, response_text)

    with :ok <- delivery_allowed(message, autonomous?),
         {:ok, exchange} <- deliver_text_part(exchange, message, state),
         :ok <- delivery_allowed(message, autonomous?),
         {:ok, exchange} <- deliver_sticker_part(exchange, message, state, autonomous?) do
      {:ok, exchange}
    end
  end

  defp ensure_delivery_plan(exchange, message, response_text) do
    plan = exchange.delivery_state["plan"]
    fingerprint = :crypto.hash(:sha256, response_text) |> Base.encode16(case: :lower)

    if is_map(plan) and
         (exchange.delivery_state["text_sent"] == true or
            plan["response_fingerprint"] == fingerprint) do
      exchange
    else
      plan =
        case sticker_response_plan(
               response_text,
               stickers_for_response(Map.get(message, :chat_id), response_text)
             ) do
          {:sticker, text, sticker} ->
            %{"text" => text, "sticker_id" => sticker.sticker_id, "emoji" => sticker.emoji || ""}

          :text ->
            %{"text" => response_text}
        end

      delivery_state =
        exchange.delivery_state
        |> Map.delete("sticker_sent")
        |> Map.put("plan", Map.put(plan, "response_fingerprint", fingerprint))

      update!(exchange, %{delivery_state: delivery_state})
    end
  end

  defp deliver_text_part(exchange, message, state) do
    if exchange.delivery_state["text_sent"] do
      {:ok, exchange}
    else
      text = exchange.delivery_state["plan"]["text"]

      result =
        cond do
          is_binary(Map.get(message, :req_id)) ->
            state.exiron.reply_text(
              state.client,
              message,
              text,
              delivery_options(exchange, message, "text_sent")
            )

          is_integer(Map.get(message, :chat_id)) ->
            state.exiron.push_text(
              state.client,
              message.chat_id,
              text,
              delivery_options(exchange, message, "text_sent")
            )

          true ->
            {:error, "message is missing a chat_id"}
        end

      checkpoint_delivery(result, exchange, "text_sent")
    end
  end

  defp deliver_sticker_part(exchange, message, state, autonomous?) do
    plan = exchange.delivery_state["plan"]

    if plan["sticker_id"] && exchange.delivery_state["sticker_sent"] != true do
      delay_ms = Map.get(state, :sticker_reply_delay_ms, @sticker_reply_delay_ms)
      if is_integer(delay_ms) and delay_ms > 0, do: Process.sleep(delay_ms)

      with :ok <- delivery_allowed(message, autonomous?) do
        result =
          state.exiron.push_sticker(
            state.client,
            message.chat_id,
            plan["sticker_id"],
            plan["emoji"],
            delivery_options(exchange, message, "sticker_sent")
          )

        checkpoint_delivery(result, exchange, "sticker_sent")
      end
    else
      {:ok, exchange}
    end
  end

  defp delivery_options(exchange, message, part) do
    identity = {exchange.id, exchange.inserted_at, exchange.chat_id, part}
    key = :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.encode16(case: :lower)
    opts = [idempotency_key: "xeba:" <> key]

    case Map.get(message, :message_thread_id) do
      id when is_integer(id) -> Keyword.put(opts, :message_thread_id, id)
      _ -> opts
    end
  end

  defp checkpoint_delivery({:ok, result}, exchange, field) do
    Conversations.checkpoint_delivery(exchange, field, result)
  end

  defp checkpoint_delivery({:error, _reason} = error, _exchange, _field), do: error

  defp delivery_allowed(%{chat_id: chat_id}, true) do
    if Conversations.autonomous_enabled?(chat_id), do: :ok, else: {:error, :autonomy_disabled}
  end

  defp delivery_allowed(_message, false), do: :ok

  defp stickers_for_response(chat_id, response_text) when is_integer(chat_id) do
    with {_text, emoji} <- trailing_emoji_split(response_text) do
      Conversations.sticker_candidates_for_emoji(chat_id, emoji)
    else
      _ -> []
    end
  end

  defp stickers_for_response(_chat_id, _response_text), do: []

  defp trailing_emoji_split(response_text) when is_binary(response_text) do
    trimmed_text = String.trim_trailing(response_text)

    case List.pop_at(String.graphemes(trimmed_text), -1) do
      {emoji, text_graphemes} when is_binary(emoji) ->
        if emoji_grapheme?(emoji) do
          {text_graphemes |> Enum.join() |> String.trim_trailing(), emoji}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp trailing_emoji_split(_response_text), do: :error

  defp emoji_grapheme?(grapheme) do
    Regex.match?(~r/[\p{So}\p{Sk}]/u, grapheme)
  end

  defp sticker_matches_emoji?(%{emoji_list: emoji_list}, emoji) when is_list(emoji_list) do
    emoji in emoji_list
  end

  defp sticker_matches_emoji?(%{emoji: sticker_emoji}, emoji), do: sticker_emoji == emoji
  defp sticker_matches_emoji?(_sticker, _emoji), do: false
end
