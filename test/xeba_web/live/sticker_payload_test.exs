defmodule XebaWeb.StickerPayloadTest do
  use XebaWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Xeba.Conversations

  test "legacy sticker records without a chat still render safely in the global console", %{
    conn: conn
  } do
    {:ok, exchange} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "legacy-chatless-sticker",
          datatype: "file",
          sticker_id: "old-sticker",
          data: <<"RIFF", 0, 0, 0, 0, "WEBP", "bytes">>
        },
        "test"
      )

    {:ok, view, _} = live(log_in_user(conn), ~p"/")
    assert has_element?(view, "#exchanges-#{exchange.id}")
    refute has_element?(view, "#exchange-#{exchange.id}-sticker")
  end

  test "large sticker pages use small metadata queries and authenticated URLs", %{conn: conn} do
    data = <<"RIFF", 0, 0, 0, 0, "WEBP">> <> :binary.copy("x", 256 * 1024)

    exchanges =
      for id <- 1..10 do
        {:ok, exchange} =
          Conversations.create_from_message(
            %ExironClient.Message{
              req_id: "payload-#{id}",
              chat_id: 604,
              msgtype: "message",
              datatype: "file",
              sticker_id: "fixture-#{id}",
              data: data
            },
            "test"
          )

        {:ok, exchange} =
          Conversations.update_exchange(exchange, %{
            status: "observed",
            delivery_state: %{"large_saved_plan" => String.duplicate("y", 256 * 1024)}
          })

        exchange
      end

    day = Conversations.transcript_calendar(604).days |> hd() |> Map.fetch!(:day)

    for metadata <- [
          Conversations.list_display_exchanges(),
          Conversations.list_display_exchanges(604),
          Conversations.transcript_page(604, day).exchanges,
          Conversations.recent_history(604)
        ] do
      assert length(metadata) == 10

      for exchange <- metadata do
        assert exchange.sticker_data == nil
        assert byte_size(exchange.sticker_data_prefix) == 12
        assert exchange.delivery_state == %{}
      end
    end

    conn = log_in_user(conn)
    {:ok, console, console_html} = live(conn, ~p"/chats/604")
    {:ok, transcript, transcript_html} = live(conn, ~p"/chats/604/transcript")
    assert byte_size(console_html) < 150_000
    assert byte_size(transcript_html) < 100_000

    for exchange <- exchanges do
      path = ~p"/chats/604/exchanges/#{exchange.id}/media"

      assert has_element?(
               console,
               "#exchange-#{exchange.id}-sticker[src='#{path}'][loading='lazy']"
             )

      assert has_element?(
               transcript,
               "#transcript-message-#{exchange.id}-user-sticker[src='#{path}'][loading='lazy']"
             )
    end
  end
end
