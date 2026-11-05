defmodule Xeba.Telegram.PollerCaptionLLMFake do
  def generate("test-model", context, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:llm_context, context})
    {:ok, "Caption received", %{input_tokens: 1, output_tokens: 2, total_tokens: 3}}
  end
end
