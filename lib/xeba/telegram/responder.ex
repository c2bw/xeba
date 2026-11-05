defmodule Xeba.Telegram.Responder do
  @moduledoc "Incoming message eligibility, AI generation, and reply completion."

  require Logger
  import Xeba.Telegram.Processing

  alias Xeba.Conversations
  alias Xeba.Telegram.{Autonomous, Delivery, FollowUp, LLM, MessageText, Prompt}

  @unsupported "I can currently respond only to text messages or media captions."
  @failure "Sorry, I couldn't generate a response right now. Please try again."

  def process(message, state) do
    result =
      case Conversations.get_by_message(message) do
        nil ->
          process_new_message(message, state)

        %{status: status} when status in ["completed", "observed", "no_answer", "failed"] ->
          :ok

        %{response_text: response_text} = exchange when is_binary(response_text) ->
          reply(exchange, message, response_text, state)

        exchange ->
          if Map.get(
               exchange.delivery_state,
               "response_requested",
               response_requested?(message, state.bot_name)
             ) do
            generate_and_reply(exchange, message, state)
          else
            observe_message(exchange)
          end
      end

    normalize_processing_result(result)
  end

  defp process_new_message(message, state) do
    requested? = response_requested?(message, state.bot_name)

    case Conversations.create_from_message(message, state.model, %{
           "response_requested" => requested?
         }) do
      {:ok, exchange} ->
        Autonomous.schedule_after_message(message.chat_id, timer_owner(state))

        if requested? do
          generate_and_reply(exchange, message, state)
        else
          observe_message(exchange)
        end

        result_for_exchange(Conversations.get_by_message(message))

      {:error, changeset} ->
        Logger.error(
          "Could not persist Exiron message #{inspect(message.req_id)}: " <>
            inspect(changeset.errors)
        )

        {:error, :message_persistence_failed}
    end
  end

  defp observe_message(exchange) do
    update!(exchange, %{
      status: "observed",
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp routed_request?(%{msgtype: "request", req_id: req_id}) when is_binary(req_id), do: true
  defp routed_request?(_message), do: false

  defp response_requested?(message, bot_name) do
    text = MessageText.content(message)

    routed_request?(message) or
      (is_binary(text) and
         (MessageText.mentioned?(text, bot_name) or
            not is_nil(Conversations.reply_target(message))))
  end

  defp generate_and_reply(exchange, message, state) do
    if is_binary(MessageText.content(message)) do
      generate_text(exchange, message, state)
    else
      exchange =
        update!(exchange, %{
          response_text: @unsupported,
          error: "unsupported datatype: #{message.datatype}"
        })

      reply(exchange, message, @unsupported, state)
    end
  end

  defp generate_text(exchange, message, state) do
    text = MessageText.content(message)

    request_text =
      if routed_request?(message) do
        MessageText.normalize(text)
      else
        MessageText.remove_mention(text, state.bot_name)
      end

    setting = Conversations.autonomous_channel_setting(message.chat_id)

    context =
      message.chat_id
      |> Conversations.recent_history(setting.context_window)
      |> exclude_current_exchange(exchange.id)
      |> Prompt.build(
        request_text,
        state.bot_name,
        message.from,
        Conversations.system_prompt_template(message.chat_id),
        Conversations.reply_target(message)
      )

    started_at = System.monotonic_time(:millisecond)

    case state.llm.generate(state.model, context, state.llm_options) do
      {:ok, response_text, usage} when is_binary(response_text) ->
        exchange = record_usage!(exchange, usage)

        if String.trim(response_text) == "NOANSWER" do
          update!(exchange, %{
            response_text: nil,
            status: "no_answer",
            completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
            latency_ms: System.monotonic_time(:millisecond) - started_at
          })
        else
          response_text = LLM.normalize_response_text(response_text)

          complete_generated_response(
            exchange,
            message,
            request_text,
            response_text,
            started_at,
            state
          )
        end

      {:error, reason} ->
        latency_ms = System.monotonic_time(:millisecond) - started_at

        exchange =
          update!(exchange, %{
            response_text: @failure,
            delivery_state: Map.put(exchange.delivery_state, "generation_failed", true),
            error: reason,
            latency_ms: latency_ms
          })

        reply(exchange, message, @failure, state)
    end
  end

  defp complete_generated_response(
         exchange,
         message,
         request_text,
         response_text,
         started_at,
         state
       ) do
    exchange =
      update!(exchange, %{
        response_text: response_text,
        latency_ms: System.monotonic_time(:millisecond) - started_at
      })

    reply_with_follow_up(exchange, message, request_text, response_text, state)
  end

  defp reply_with_follow_up(exchange, message, request_text, response_text, state) do
    reply_after_delivery(exchange, message, response_text, state, fn ->
      FollowUp.schedule(message.chat_id, FollowUp.prompt(request_text),
        follow_up_candidate?: true,
        timer_owner: timer_owner(state)
      )
    end)
  end

  defp reply(exchange, message, response_text, state) do
    reply_after_delivery(exchange, message, response_text, state, fn -> :ok end)
  end

  defp reply_after_delivery(exchange, message, response_text, state, after_deliver) do
    case Delivery.deliver(exchange, message, response_text, state) do
      {:ok, exchange} ->
        after_deliver.()

        failed? =
          exchange.delivery_state["generation_failed"] == true or
            (not is_nil(exchange.error) and exchange.status != "reply_failed")

        update!(exchange, %{
          status: if(failed?, do: "failed", else: "completed"),
          error: if(failed?, do: exchange.error, else: nil),
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

        :ok

      {:error, error} ->
        latest = Xeba.Repo.get!(Xeba.Conversations.Exchange, exchange.id)
        update!(latest, %{status: "reply_failed", error: error_message(error)})
        {:error, :reply_delivery_failed}
    end
  end

  defp result_for_exchange(%{status: "reply_failed"}), do: {:error, :reply_delivery_failed}
  defp result_for_exchange(_exchange), do: :ok

  defp normalize_processing_result({:error, _} = error), do: error
  defp normalize_processing_result(_result), do: :ok
end
