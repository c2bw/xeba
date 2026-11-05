defmodule Xeba.Telegram.LLM do
  require Logger

  @weekday_line ~r/\A[\x{FEFF}\x{200B}\x{200C}\x{200D}\x{2060}]*(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday),[^\r\n\v\f\x{0085}\x{2028}\x{2029}]*(?:\r\n|[\n\v\f\r\x{0085}\x{2028}\x{2029}])?/u

  def generate(model, context, opts) do
    started_at = System.monotonic_time(:millisecond)
    do_generate(model, context, opts, started_at)
  end

  defp do_generate(model, context, opts, started_at) do
    endpoint =
      opts
      |> Keyword.get(:endpoint)
      |> normalize_endpoint()

    model_spec = model_spec(model, endpoint)

    request_opts =
      [api_key: Keyword.fetch!(opts, :api_key)]
      |> maybe_put(:req_http_options, Keyword.get(opts, :req_http_options))

    case ReqLLM.generate_text(model_spec, context, request_opts) do
      {:ok, response} ->
        handle_api_response(model, response, started_at)

      {:error, error} ->
        log_api_error(model, error, started_at)
        {:error, error_message(error)}
    end
  rescue
    error ->
      log_api_error(model, error, started_at)
      {:error, Exception.message(error)}
  end

  defp handle_api_response(model, response, started_at) do
    if text_response?(response) do
      text = ReqLLM.Response.text(response)
      log_api_response(:info, model, response_summary(response), started_at)
      {:ok, normalize_response_text(text), ReqLLM.Response.usage(response) || %{}}
    else
      log_api_response(:warning, model, response_summary(response), started_at)
      {:error, "Malformed API response: missing assistant text"}
    end
  end

  defp model_spec(model, nil), do: model

  defp model_spec(model, endpoint) do
    %{
      provider: :openai,
      id: model,
      provider_model_id: model,
      base_url: endpoint,
      capabilities: %{chat: true},
      extra: %{wire: %{protocol: "openai_chat"}}
    }
  end

  defp normalize_endpoint(nil), do: nil

  defp normalize_endpoint(endpoint) when is_binary(endpoint) do
    case endpoint |> String.trim() |> String.trim_trailing("/") do
      "" -> nil
      endpoint -> endpoint
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp text_response?(%ReqLLM.Response{message: %ReqLLM.Message{content: content}})
       when is_list(content) do
    Enum.any?(content, &(&1.type == :text))
  end

  defp text_response?(_response), do: false

  defp response_summary(response) do
    usage = ReqLLM.Response.usage(response) || %{}

    %{
      usage:
        usage
        |> Map.take([:input_tokens, :output_tokens, :total_tokens])
        |> Map.filter(fn {_key, value} -> is_number(value) end)
    }
  end

  defp log_api_error(model, error, started_at) do
    status = error_status(error)
    level = if is_integer(status) and status < 500, do: :warning, else: :error
    error_type = if is_struct(error), do: error.__struct__, else: :api_error

    log_api_response(level, model, %{status: status, error_type: error_type}, started_at)
  end

  defp log_api_response(level, model, metadata, started_at) do
    metadata = Map.put(metadata, :duration_ms, System.monotonic_time(:millisecond) - started_at)
    Logger.log(level, "AI API response model=#{inspect(model)} metadata=#{inspect(metadata)}")
  end

  defp error_status(%{status: status}) when is_integer(status), do: status
  defp error_status(_error), do: nil

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)

  def normalize_response_text(response_text) when is_binary(response_text) do
    response_text =
      response_text
      |> String.trim()
      |> then(&Regex.replace(@weekday_line, &1, ""))
      |> String.trim()

    if response_text == "" do
      "..."
    else
      response_text
    end
  end

  def normalize_response_text(_response_text), do: "..."
end
