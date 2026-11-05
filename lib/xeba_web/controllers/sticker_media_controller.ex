defmodule XebaWeb.StickerMediaController do
  use XebaWeb, :controller

  alias Xeba.Conversations

  def show(conn, %{"chat_id" => chat, "id" => id}) do
    serve(conn, chat, id, &Conversations.get_sticker_media/2)
  end

  def exchange(conn, %{"chat_id" => chat, "id" => id}) do
    serve(conn, chat, id, &Conversations.get_exchange_sticker_media/2)
  end

  defp serve(conn, chat, id, fetch) do
    with {:ok, chat_id} <- parse_integer(chat),
         {:ok, id} when id > 0 <- parse_integer(id),
         %{data: data} when is_binary(data) <- fetch.(chat_id, id),
         type when type in [:image, :video] <- Conversations.sticker_media_type(data) do
      content_type = if type == :image, do: "image/webp", else: "video/webm"

      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_content_type(content_type, nil)
      |> send_resp(:ok, data)
    else
      _ -> send_resp(conn, :not_found, "Not found")
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {number, ""} when number in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 ->
        {:ok, number}

      _ ->
        :error
    end
  end
end
