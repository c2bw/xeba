defmodule Xeba.Telegram.Autonomous do
  @moduledoc "Autonomous generation and bounded recovery of interrupted exchanges."

  import Xeba.Telegram.Processing

  alias Xeba.Conversations
  alias Xeba.Telegram.{Delivery, FollowUp, LLM, Prompt}

  @autonomous_delay_ms :timer.minutes(2)
  @autonomous_delivery_attempts 4
  @autonomous_prompt "Initiate a natural new message in this group chat based on the conversation."

  def default_prompt, do: @autonomous_prompt

  def retryable_ids,
    do: Conversations.retryable_autonomous_delivery_ids(@autonomous_delivery_attempts)

  def schedule_after_message(chat_id, owner) when is_integer(chat_id) do
    setting = Conversations.autonomous_channel_setting(chat_id)

    if Conversations.autonomous_enabled?(chat_id) and
         rem(Conversations.count_chat_messages(chat_id), setting.message_trigger) == 0 do
      Process.send_after(owner, {:autonomous_message, chat_id}, @autonomous_delay_ms)
    end
  end

  def schedule_after_message(_chat_id, _owner), do: :ok

  def generate(chat_id, prompt, state, opts) do
    checkpoint = %{"autonomous_attempts" => 1, "autonomous_prompt" => prompt}

    with {:ok, exchange} <- Conversations.create_autonomous(chat_id, state.model, checkpoint) do
      generate_autonomous_exchange(exchange, prompt, state, opts)
    end
  end

  defp generate_autonomous_exchange(exchange, prompt, state, opts) do
    chat_id = exchange.chat_id
    setting = Conversations.autonomous_channel_setting(chat_id)

    context =
      chat_id
      |> Conversations.recent_history(setting.context_window)
      |> exclude_current_exchange(exchange.id)
      |> Prompt.build(
        prompt,
        state.bot_name,
        nil,
        Conversations.system_prompt_template(chat_id)
      )

    started_at = System.monotonic_time(:millisecond)

    case state.llm.generate(state.model, context, state.llm_options) do
      {:ok, response_text, usage} when is_binary(response_text) ->
        exchange = record_usage!(exchange, usage)

        if String.trim(response_text) == "NOANSWER" do
          update!(exchange, %{
            status: "no_answer",
            latency_ms: System.monotonic_time(:millisecond) - started_at,
            completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
        else
          response_text = LLM.normalize_response_text(response_text)
          deliver_autonomous(exchange, chat_id, response_text, started_at, state, opts)
        end

      {:error, reason} ->
        update!(exchange, %{
          status: "failed",
          error: reason,
          latency_ms: System.monotonic_time(:millisecond) - started_at,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
    end
  end

  def retry(id, state) do
    case Xeba.Repo.get(Xeba.Conversations.Exchange, id) do
      %{msgtype: "autonomous", status: status} = exchange
      when status in ["pending", "reply_failed"] ->
        attempts = Map.get(exchange.delivery_state, "autonomous_attempts", 0)
        due_at = Map.get(exchange.delivery_state, "autonomous_retry_at", 0)

        cond do
          attempts >= @autonomous_delivery_attempts ->
            if status == "pending" do
              plan = exchange.delivery_state["plan"] || %{}

              delivered? =
                exchange.delivery_state["text_sent"] == true and
                  (is_nil(plan["sticker_id"]) or exchange.delivery_state["sticker_sent"] == true)

              update!(exchange, %{
                status:
                  cond do
                    delivered? -> "completed"
                    is_binary(exchange.response_text) -> "reply_failed"
                    true -> "failed"
                  end,
                error:
                  if(delivered?,
                    do: nil,
                    else: "Autonomous processing interrupted; retry limit reached"
                  ),
                completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
              })
            end

          not Conversations.autonomous_enabled?(exchange.chat_id) or
              due_at > System.system_time(:millisecond) ->
            :ok

          true ->
            checkpoint =
              exchange.delivery_state
              |> Map.delete("autonomous_retry_at")
              |> Map.put("autonomous_attempts", attempts + 1)

            exchange = update!(exchange, %{status: "pending", delivery_state: checkpoint})

            if is_binary(exchange.response_text) do
              deliver_autonomous(
                exchange,
                exchange.chat_id,
                exchange.response_text,
                System.monotonic_time(:millisecond),
                state,
                schedule_follow_up?: false
              )
            else
              prompt = Map.get(checkpoint, "autonomous_prompt", @autonomous_prompt)
              generate_autonomous_exchange(exchange, prompt, state, schedule_follow_up?: false)
            end
        end

      _ ->
        :ok
    end

    :ok
  end

  defp deliver_autonomous(exchange, chat_id, response_text, started_at, state, opts) do
    attempts = Map.fetch!(exchange.delivery_state, "autonomous_attempts")
    exchange = update!(exchange, %{response_text: response_text})

    if Conversations.autonomous_enabled?(chat_id) do
      case Delivery.deliver(exchange, %{chat_id: chat_id}, response_text, state, true) do
        {:ok, exchange} ->
          FollowUp.schedule(
            chat_id,
            FollowUp.prompt(),
            Keyword.put(opts, :timer_owner, timer_owner(state))
          )

          update!(exchange, %{
            status: "completed",
            error: nil,
            latency_ms: System.monotonic_time(:millisecond) - started_at,
            completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        {:error, error} ->
          delay = Map.get(state, :autonomous_retry_delay_ms, 1_000 * Integer.pow(2, attempts - 1))
          latest = Xeba.Repo.get!(Xeba.Conversations.Exchange, exchange.id)

          checkpoint =
            Map.put(
              latest.delivery_state,
              "autonomous_retry_at",
              System.system_time(:millisecond) + delay
            )

          failed =
            update!(latest, %{
              status: "reply_failed",
              error: "Exiron push failed: #{error_message(error)}",
              delivery_state: checkpoint,
              latency_ms: System.monotonic_time(:millisecond) - started_at
            })

          if attempts < @autonomous_delivery_attempts and
               Conversations.autonomous_enabled?(chat_id) do
            Process.send_after(
              timer_owner(state),
              {:retry_autonomous_delivery, exchange.id},
              delay
            )
          end

          failed
      end
    else
      update!(exchange, %{status: "no_answer", response_text: nil})
    end
  end
end
