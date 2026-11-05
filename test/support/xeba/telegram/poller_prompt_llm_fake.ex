defmodule Xeba.Telegram.PollerPromptLLMFake do
  def generate("test-model", context, opts) do
    system_prompt =
      context.messages
      |> hd()
      |> Map.fetch!(:content)
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("", & &1.text)

    send(Keyword.fetch!(opts, :test_pid), {:llm_system_prompt, system_prompt})

    if callback = Keyword.get(opts, :before_response), do: callback.()

    {:ok, "Prompt received", %{input_tokens: 1, output_tokens: 2, total_tokens: 3}}
  end
end
