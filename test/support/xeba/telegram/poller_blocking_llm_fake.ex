defmodule Xeba.Telegram.PollerBlockingLLMFake do
  def generate(_model, _context, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:generation_waiting, self()})

    receive do
      :finish -> {:ok, "Released response", %{total_tokens: 1}}
    end
  end
end
