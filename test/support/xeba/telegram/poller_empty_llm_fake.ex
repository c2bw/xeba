defmodule Xeba.Telegram.PollerEmptyLLMFake do
  def generate("test-model", _context, _opts) do
    {:ok, "  ", %{input_tokens: 1, output_tokens: 0, total_tokens: 1}}
  end
end
