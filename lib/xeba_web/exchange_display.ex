defmodule XebaWeb.ExchangeDisplay do
  @moduledoc false
  use XebaWeb, :verified_routes

  alias Xeba.Conversations

  def request_text(%{request_text: text}) when is_binary(text) and text != "", do: text

  def request_text(%{sticker_emoji: emoji})
      when is_binary(emoji) and emoji != "" do
    "[sticker #{emoji}]"
  end

  def request_text(%{sticker_id: id}) when is_binary(id) and id != "", do: "[sticker]"
  def request_text(%{datatype: "sticker"}), do: "[sticker]"
  def request_text(%{datatype: datatype}), do: "[#{datatype} message]"

  def sticker_id(%{sticker_id: sticker_id}) when is_binary(sticker_id) and sticker_id != "",
    do: sticker_id

  def sticker_id(_exchange), do: nil

  def sticker_request?(%{request_text: text}) when is_binary(text) and text != "", do: false
  def sticker_request?(%{sticker_emoji: emoji}) when is_binary(emoji) and emoji != "", do: true
  def sticker_request?(%{sticker_id: id}) when is_binary(id) and id != "", do: true
  def sticker_request?(%{datatype: "sticker"}), do: true
  def sticker_request?(_exchange), do: false

  def sticker_media(%{chat_id: chat_id, id: id} = exchange)
      when is_integer(chat_id) and is_integer(id) do
    case Conversations.sticker_media_type(exchange.sticker_data_prefix) do
      :image ->
        %{type: :image, src: ~p"/chats/#{exchange.chat_id}/exchanges/#{exchange.id}/media"}

      :video ->
        %{type: :video, src: ~p"/chats/#{exchange.chat_id}/exchanges/#{exchange.id}/media"}

      :unsupported_animation ->
        %{type: :unsupported_animation}

      nil ->
        nil
    end
  end

  def sticker_media(_exchange), do: nil

  def sender_name(exchange) do
    [exchange.sender_first_name, exchange.sender_last_name]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" ")
    |> case do
      "" when is_binary(exchange.sender_username) -> "@#{exchange.sender_username}"
      "" when is_integer(exchange.sender_id) -> "Telegram user #{exchange.sender_id}"
      "" -> "Unknown sender"
      name -> name
    end
  end
end
