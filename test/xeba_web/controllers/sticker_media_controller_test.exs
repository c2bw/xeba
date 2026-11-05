defmodule XebaWeb.StickerMediaControllerTest do
  use XebaWeb.ConnCase, async: true

  alias Xeba.Conversations.ChatSticker

  setup do
    data = <<"RIFF", 0, 0, 0, 0, "WEBP", "payload">>

    sticker =
      Xeba.Repo.insert!(%ChatSticker{
        chat_id: 42,
        sticker_id: "media",
        data: data,
        last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, sticker: sticker, data: data}
  end

  test "media requires authentication", %{conn: conn, sticker: sticker} do
    conn =
      conn
      |> put_req_header("accept", "image/webp")
      |> get(~p"/chats/42/stickers/#{sticker.id}/media")

    assert redirected_to(conn) == ~p"/log-in"
  end

  test "serves authenticated media with its binary content type and private caching", %{
    conn: conn,
    sticker: sticker,
    data: data
  } do
    conn =
      conn
      |> log_in_user()
      |> put_req_header("accept", "image/webp")
      |> get(~p"/chats/42/stickers/#{sticker.id}/media")

    assert response(conn, 200) == data
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "requires the media record to belong to the requested chat", %{
    conn: conn,
    sticker: sticker
  } do
    conn = conn |> log_in_user() |> get(~p"/chats/99/stickers/#{sticker.id}/media")
    assert response(conn, 404) == "Not found"
  end

  test "rejects malformed and unsupported media without exposing bytes", %{
    conn: conn,
    sticker: sticker
  } do
    authenticated = log_in_user(conn)
    assert authenticated |> get("/chats/42/stickers/bad/media") |> response(404) == "Not found"

    assert authenticated
           |> get("/chats/42/stickers/999999999999999999999999/media")
           |> response(404) == "Not found"

    Xeba.Repo.update!(Ecto.Changeset.change(sticker, data: "<script>not an image</script>"))

    assert authenticated |> get(~p"/chats/42/stickers/#{sticker.id}/media") |> response(404) ==
             "Not found"
  end
end
