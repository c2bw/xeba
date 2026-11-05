defmodule Xeba.Telegram.PromptTest do
  use ExUnit.Case, async: true

  alias Xeba.Conversations.Exchange
  alias Xeba.Telegram.Prompt

  test "builds ordered context with system prompt, history, and current request" do
    history = [
      %Exchange{
        request_text: "first",
        response_text: "one",
        sender_first_name: "Ada",
        sender_username: "ada",
        sender_id: 123
      },
      %Exchange{request_text: "second", response_text: "two"}
    ]

    context =
      Prompt.build(history, "latest", "andrebot", %{
        "id" => 456,
        "first_name" => "Grace",
        "last_name" => "Hopper",
        "username" => "grace"
      })

    assert Enum.map(context.messages, & &1.role) == [
             :system,
             :user,
             :assistant,
             :user,
             :assistant,
             :user
           ]

    [system_message | conversation_messages] = Enum.map(context.messages, &message_text/1)

    assert_system_prompt(system_message, "andrebot")
    assert_user_message(Enum.at(conversation_messages, 0))
    assert Enum.at(conversation_messages, 1) == "one"
    assert_user_message(Enum.at(conversation_messages, 2))
    assert Enum.at(conversation_messages, 3) == "two"
    assert_user_message(Enum.at(conversation_messages, 4))

    assert Enum.at(conversation_messages, 0) =~ "; Sender: Ada (@ada, id:123)]\n"

    assert Enum.at(conversation_messages, 4) =~
             "; Sender: Grace Hopper (@grace, id:456)]\n"

    assert Enum.map(conversation_messages, &message_body/1) == [
             "first",
             "one",
             "second",
             "two",
             "latest"
           ]
  end

  test "previews the same system and history messages without a future request" do
    history = [%Exchange{request_text: "hello", response_text: "hi"}]

    [system_message | conversation_messages] = Prompt.preview(history, "andrebot")

    assert system_message.role == :system
    assert_system_prompt(system_message.content, "andrebot")
    assert_user_message(Enum.at(conversation_messages, 0).content)
    assert Enum.at(conversation_messages, 1).content == "hi"

    assert Enum.map(
             conversation_messages,
             &Map.update!(&1, :content, fn content -> message_body(content) end)
           ) == [
             %{role: :user, content: "hello"},
             %{role: :assistant, content: "hi"}
           ]
  end

  test "includes observed chat messages without inventing assistant responses" do
    history = [
      %Exchange{request_text: "ambient message", response_text: nil},
      %Exchange{request_text: "ai question", response_text: "ai answer"}
    ]

    [system_message | conversation_messages] = Prompt.preview(history, "andrebot")

    assert_system_prompt(system_message.content, "andrebot")
    assert_user_message(Enum.at(conversation_messages, 0).content)
    assert_user_message(Enum.at(conversation_messages, 1).content)
    assert Enum.at(conversation_messages, 2).content == "ai answer"

    assert Enum.map(conversation_messages, &{&1.role, message_body(&1.content)}) == [
             {:user, "ambient message"},
             {:user, "ai question"},
             {:assistant, "ai answer"}
           ]
  end

  test "includes sticker emoji equivalents in history context" do
    history = [
      %Exchange{
        sticker_emoji: "laugh",
        sender_first_name: "Ada",
        sender_username: "ada"
      },
      %Exchange{request_text: "after", response_text: "reply"}
    ]

    [system_message | conversation_messages] = Prompt.preview(history, "andrebot")

    assert_system_prompt(system_message.content, "andrebot")
    assert_user_message(Enum.at(conversation_messages, 0).content)
    assert_user_message(Enum.at(conversation_messages, 1).content)
    assert Enum.at(conversation_messages, 2).content == "reply"

    assert Enum.map(conversation_messages, &{&1.role, message_body(&1.content)}) == [
             {:user, "[sticker laugh]"},
             {:user, "after"},
             {:assistant, "reply"}
           ]
  end

  test "timestamps user context messages but not assistant messages" do
    history = [
      %Exchange{
        request_text: "question",
        response_text: "answer",
        inserted_at: ~U[2020-01-15 12:00:00Z],
        completed_at: ~U[2021-02-16 12:00:00Z]
      }
    ]

    [_system_message, user_message, assistant_message] = Prompt.preview(history, "andrebot")

    assert user_message.content =~ ~r/^\[Datetime: [^\]]*2020-01-/
    assert assistant_message.content == "answer"
  end

  test "does not timestamp autonomous assistant messages" do
    history = [
      %Exchange{
        msgtype: "autonomous",
        response_text: "A spontaneous thought",
        completed_at: ~U[2021-02-16 12:00:00Z]
      }
    ]

    [_system_message, assistant_message] = Prompt.preview(history, "andrebot")

    assert assistant_message == %{role: :assistant, content: "A spontaneous thought"}
  end

  test "renders supported placeholders and leaves unknown placeholders unchanged" do
    rendered =
      Prompt.render_template(
        "{{bot_name}} at {{current_datetime}} in {{timezone}} {{unknown}}",
        "andrebot"
      )

    assert rendered =~ "andrebot at "
    assert rendered =~ System.get_env("TZ", "Etc/UTC")
    assert rendered =~ "{{unknown}}"
    refute rendered =~ "{{bot_name}}"
    refute rendered =~ "{{current_datetime}}"
    refute rendered =~ "{{timezone}}"
  end

  test "build and preview use the same custom system prompt" do
    template = "Custom system prompt for {{bot_name}}."
    context = Prompt.build([], "hello", "andrebot", nil, template)
    [preview_system] = Prompt.preview([], "andrebot", template)

    assert context.messages |> hd() |> message_text() == "Custom system prompt for andrebot."
    assert preview_system == %{role: :system, content: "Custom system prompt for andrebot."}
  end

  defp message_text(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp assert_system_prompt(prompt, bot_name) do
    timezone = Regex.escape(System.get_env("TZ", "Etc/UTC"))

    assert prompt =~ "You are a companion named #{bot_name}"

    assert prompt =~
             ~r/The current date and time is (Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \(#{timezone}\)\./

    assert prompt =~ "Try not to repeat yourself."
  end

  defp assert_user_message(message) do
    assert message =~
             ~r/^\[Datetime: (Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(; Sender: [^\]]+)?\]\n/
  end

  defp message_body(message) do
    message
    |> String.split("\n", parts: 2)
    |> List.last()
  end
end
