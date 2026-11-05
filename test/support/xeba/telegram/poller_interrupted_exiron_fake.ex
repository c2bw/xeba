defmodule Xeba.Telegram.PollerInterruptedExironFake do
  def push_text(client, chat_id, text, _opts \\ []) do
    send(client.owner, {:autonomous_delivery_waiting, self(), chat_id, text})

    receive do
      :finish -> {:ok, %{}}
    end
  end
end
