defmodule Xeba.Telegram.ReceiptRequestTest do
  use ExUnit.Case, async: true
  alias Xeba.Telegram.Exiron

  test "the SDK transports receipt requests and idempotency keys for replies and pushes" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      send(owner, {:request, conn.request_path, payload})

      Req.Test.json(conn, %{
        ok: true,
        sent: 1,
        receipts: [%{service_id: 222, chat_id: 910, message_ids: [901]}]
      })
    end)

    client =
      Exiron.new(
        base_url: "http://exiron.test",
        token: "test",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    message = %ExironClient.Message{req_id: "original"}
    opts = [idempotency_key: "xeba:test", message_thread_id: 7]
    assert {:ok, %{"receipts" => [_]}} = Exiron.reply_text(client, message, "hello", opts)

    assert_receive {:request, "/api/idempotent/responses",
                    %{
                      "delivery_receipts" => true,
                      "idempotency_key" => "xeba:test",
                      "req_id" => "original"
                    }}

    assert {:ok, _} = Exiron.push_text(client, 910, "hello", opts)

    assert_receive {:request, "/api/idempotent/push",
                    %{"delivery_receipts" => true, "message_thread_id" => 7, "chat_id" => 910}}

    assert {:ok, _} = Exiron.push_sticker(client, 910, "file-id", "🔥", opts)

    assert_receive {:request, "/api/idempotent/push",
                    %{"delivery_receipts" => true, "datatype" => "sticker"}}
  end
end
