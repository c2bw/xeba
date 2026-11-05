defmodule Xeba.Telegram.Exiron do
  def new(opts), do: ExironClient.new(opts)

  def start_poller(opts) do
    result = ExironClient.Poller.start_link(opts)

    case result do
      {:ok, pid} ->
        Xeba.Telegram.Poller.monitor_connection(pid)
        result

      _other ->
        result
    end
  end

  def status(client), do: ExironClient.status(client)

  def reply_text(client, message, text, opts \\ []) do
    ExironClient.respond(
      client,
      message,
      "text",
      text,
      Keyword.put(opts, :delivery_receipts, true)
    )
  end

  def reply_sticker(client, message, sticker_id, emoji),
    do: ExironClient.reply_sticker(client, message, sticker_id, emoji)

  def push_text(client, chat_id, text, opts \\ []) do
    ExironClient.push_text(client, chat_id, text, Keyword.put(opts, :delivery_receipts, true))
  end

  def push_sticker(client, chat_id, sticker_id, emoji, opts \\ []) do
    ExironClient.push_sticker(
      client,
      chat_id,
      sticker_id,
      emoji,
      Keyword.put(opts, :delivery_receipts, true)
    )
  end
end
