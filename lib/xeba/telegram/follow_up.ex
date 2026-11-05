defmodule Xeba.Telegram.FollowUp do
  @moduledoc "Follow-up reply selection and delayed scheduling."

  alias Xeba.Conversations

  @follow_up_delay_ms :timer.seconds(15)
  @follow_up_response_roll 1
  @response_roll_sides 4
  @follow_up_prompt "Send one additional natural follow-up message in this group chat. Do not repeat your previous message."

  def prompt, do: @follow_up_prompt

  @doc false
  def response?(roll \\ :rand.uniform(@response_roll_sides))
  def response?(@follow_up_response_roll), do: true
  def response?(_roll), do: false

  def schedule(chat_id, prompt, opts) when is_integer(chat_id) do
    if Conversations.autonomous_enabled?(chat_id) and schedule?(opts) do
      Process.send_after(
        Keyword.get(opts, :timer_owner, self()),
        {:follow_up_response, chat_id, prompt},
        @follow_up_delay_ms
      )
    end
  end

  def schedule(_chat_id, _prompt, _opts), do: :ok

  @doc false
  def schedule?(opts, roll \\ :rand.uniform(@response_roll_sides)) do
    Keyword.get(opts, :schedule_follow_up?, true) and
      Keyword.get(opts, :follow_up_candidate?, false) and
      response?(roll)
  end

  def prompt(request_text) do
    """
    #{@follow_up_prompt}

    Original message: #{request_text}
    """
  end
end
