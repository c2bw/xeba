defmodule XebaWeb.ExchangeMediaControllerTest do
  use XebaWeb.ConnCase, async: true
  alias Xeba.Conversations

  setup do
    data = <<"RIFF", 0, 0, 0, 0, "WEBP", "payload">>

    {:ok, exchange} =
      Conversations.create_from_message(
        %ExironClient.Message{
          req_id: "exchange-media",
          chat_id: 42,
          datatype: "file",
          sticker_id: "exchange-sticker",
          data: data
        },
        "test"
      )

    {:ok, exchange: exchange, data: data}
  end

  test "exchange media requires a valid session", %{conn: conn, exchange: exchange} do
    path = ~p"/chats/42/exchanges/#{exchange.id}/media"

    assert conn |> put_req_header("accept", "image/webp") |> get(path) |> redirected_to() ==
             ~p"/log-in"

    conn = log_in_user(conn)
    Xeba.Sessions.revoke(get_session(conn, :xeba_authenticated))
    assert conn |> get(path) |> redirected_to() == ~p"/log-in"
  end

  test "returns the exchange's original media with private caching and a precise content type", %{
    conn: conn,
    exchange: exchange,
    data: data
  } do
    [bank] = Conversations.list_chat_stickers(42)
    Xeba.Repo.update!(Ecto.Changeset.change(bank, data: "different bank bytes"))
    authenticated = log_in_user(conn)

    conn =
      authenticated
      |> put_req_header("accept", "image/webp")
      |> get(~p"/chats/42/exchanges/#{exchange.id}/media")

    assert response(conn, 200) == data
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    video = <<0x1A, 0x45, 0xDF, 0xA3, "video bytes">>
    {:ok, _} = Conversations.update_exchange(exchange, %{sticker_data: video})

    conn =
      authenticated
      |> put_req_header("accept", "video/webm")
      |> get(~p"/chats/42/exchanges/#{exchange.id}/media")

    assert response(conn, 200) == video
    assert get_resp_header(conn, "content-type") == ["video/webm"]
  end

  test "rejects another chat, invalid IDs, and unsupported bytes", %{
    conn: conn,
    exchange: exchange
  } do
    conn = log_in_user(conn)

    for path <- [
          ~p"/chats/99/exchanges/#{exchange.id}/media",
          "/chats/42/exchanges/bad/media",
          "/chats/42/exchanges/-1/media",
          "/chats/42/exchanges/99999999999999999999999/media"
        ] do
      assert conn |> get(path) |> response(404) == "Not found"
    end

    {:ok, _} = Conversations.update_exchange(exchange, %{sticker_data: "<script>bad</script>"})

    assert conn |> get(~p"/chats/42/exchanges/#{exchange.id}/media") |> response(404) ==
             "Not found"
  end
end
