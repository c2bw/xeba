defmodule Xeba.Telegram.PollerRetryExironFake do
  def reply_text(client, message, text, _opts \\ []) do
    send(client.owner, {:reply_text, message, text})
    result(client, :text)
  end

  def push_text(client, chat_id, text, _opts \\ []) do
    send(client.owner, {:push_text, chat_id, text})
    result(client, :text)
  end

  def push_sticker(client, chat_id, id, emoji, _opts \\ []) do
    send(client.owner, {:push_sticker, chat_id, id, emoji})
    result(client, :sticker)
  end

  defp result(client, part) do
    Agent.get_and_update(client.failures, fn failures ->
      remaining = Map.get(failures, part, 0)

      if remaining > 0 do
        {{:error, :temporary_failure}, Map.put(failures, part, remaining - 1)}
      else
        {{:ok, %{}}, failures}
      end
    end)
  end
end
