defmodule Xeba.Telegram.PollerLLMFake do
  def generate("test-model", _context, _opts) do
    {:ok, "Here you go \u{1F525}", %{input_tokens: 1, output_tokens: 4, total_tokens: 5}}
  end
end
