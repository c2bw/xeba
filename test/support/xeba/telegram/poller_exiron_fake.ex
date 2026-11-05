defmodule Xeba.Telegram.PollerExironFake do
  def reply_text(%{owner: owner}, message, text, _opts \\ []) do
    send(owner, {:reply_text, message, text})
    {:ok, %{ok: true}}
  end

  def reply_sticker(%{owner: owner}, message, sticker_id, emoji) do
    send(owner, {:reply_sticker, message, sticker_id, emoji})
    {:ok, %{ok: true}}
  end

  def push_text(%{owner: owner}, chat_id, text, _opts \\ []) do
    send(owner, {:push_text, chat_id, text})
    {:ok, %{ok: true}}
  end

  def push_sticker(%{owner: owner}, chat_id, sticker_id, emoji, _opts \\ []) do
    send(owner, {:push_sticker, chat_id, sticker_id, emoji})
    {:ok, %{ok: true}}
  end
end
