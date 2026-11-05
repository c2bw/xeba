defmodule Xeba.Telegram.Processing do
  @moduledoc "Exchange updates and worker timer ownership shared by Telegram processing."

  alias Xeba.Conversations

  def exclude_current_exchange(history, exchange_id) do
    Enum.reject(history, &(&1.id == exchange_id))
  end

  def timer_owner(state), do: Map.get(state, :timer_owner, self())

  def update!(exchange, attrs) do
    {:ok, exchange} = Conversations.update_exchange(exchange, attrs)
    exchange
  end

  defp usage_value(usage, key) when is_map(usage) do
    Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
  end

  defp usage_value(_, _), do: nil

  def record_usage!(exchange, usage) do
    total_tokens = usage_value(usage, :total_tokens)

    attrs = %{
      input_tokens: usage_value(usage, :input_tokens),
      output_tokens: usage_value(usage, :output_tokens),
      total_tokens: total_tokens
    }

    attrs =
      if is_nil(total_tokens) do
        attrs
      else
        Map.put(attrs, :tokens_used_at, DateTime.utc_now())
      end

    update!(exchange, attrs)
  end

  def error_message(%{message: message}) when is_binary(message), do: message
  def error_message(error) when is_binary(error), do: error
  def error_message(error), do: inspect(error)
end
