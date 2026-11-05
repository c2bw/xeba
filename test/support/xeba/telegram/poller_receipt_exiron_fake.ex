defmodule Xeba.Telegram.PollerReceiptExironFake do
  def reply_text(client, message, text, opts) do
    send(client.owner, {:reply_text, message, text, opts})
    receipt(client, message.chat_id, opts)
  end

  def push_text(client, chat, text, opts) do
    send(client.owner, {:push_text, chat, text, opts})
    receipt(client, chat, opts)
  end

  def push_sticker(client, chat, id, emoji, opts) do
    send(client.owner, {:push_sticker, chat, id, emoji, opts})
    receipt(client, chat, opts)
  end

  defp receipt(client, chat, opts) do
    ids = Agent.get_and_update(client.ids, fn n -> {[n + 1, n + 2], n + 2} end)

    {:ok,
     %{
       "receipts" => [
         %{
           "service_id" => 222,
           "chat_id" => chat,
           "message_thread_id" => opts[:message_thread_id],
           "message_ids" => ids
         }
       ]
     }}
  end
end
