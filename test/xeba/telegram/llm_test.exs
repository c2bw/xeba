defmodule Xeba.Telegram.LLMTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ReqLLM.Context
  alias Xeba.Telegram.LLM

  test "calls an OpenAI-compatible Chat Completions endpoint" do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, {
        :request,
        conn.method,
        conn.request_path,
        Plug.Conn.get_req_header(conn, "authorization"),
        conn.body_params
      })

      Req.Test.json(conn, chat_completion_response("Hello from the compatible API"))
    end

    context =
      Context.new([
        Context.system("Be concise."),
        Context.user("Hello")
      ])

    assert {:ok, "Hello from the compatible API", usage} =
             LLM.generate("gpt-5", context,
               endpoint: "https://ai.example/v1/",
               api_key: "test-secret",
               req_http_options: [plug: plug]
             )

    assert usage.input_tokens == 8
    assert usage.output_tokens == 5
    assert usage.total_tokens == 13

    assert_receive {
      :request,
      "POST",
      "/v1/chat/completions",
      ["Bearer test-secret"],
      %{
        "model" => "gpt-5",
        "messages" => [
          %{"role" => "system", "content" => "Be concise."},
          %{"role" => "user", "content" => "Hello"}
        ]
      }
    }
  end

  test "uses ReqLLM's native provider construction when the endpoint is empty" do
    test_pid = self()

    plug = fn conn ->
      send(test_pid, {
        :native_request,
        conn.method,
        conn.request_path,
        Plug.Conn.get_req_header(conn, "authorization"),
        conn.body_params
      })

      Req.Test.json(conn, chat_completion_response("Hello from ReqLLM"))
    end

    assert {:ok, "Hello from ReqLLM", _usage} =
             LLM.generate(
               "cerebras:gpt-oss-120b",
               Context.new([Context.user("Hello")]),
               endpoint: "   ",
               api_key: "csk-test",
               req_http_options: [plug: plug]
             )

    assert_receive {
      :native_request,
      "POST",
      "/v1/chat/completions",
      ["Bearer csk-test"],
      %{
        "model" => "gpt-oss-120b",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }
    }
  end

  test "normalizes empty text returned by a compatible endpoint" do
    plug = fn conn ->
      Req.Test.json(conn, chat_completion_response("  \n"))
    end

    assert {:ok, "...", _usage} =
             LLM.generate("empty-response-model", Context.new([Context.user("Hello")]),
               endpoint: "https://ai.example/v1",
               api_key: "test-secret",
               req_http_options: [plug: plug]
             )
  end

  test "logs only metadata for successful API responses" do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    plug = fn conn ->
      Req.Test.json(conn, chat_completion_response("Logged response"))
    end

    log =
      capture_log([level: :info], fn ->
        assert {:ok, "Logged response", _usage} =
                 LLM.generate("logged-model", Context.new([Context.user("Hello")]),
                   endpoint: "https://ai.example/v1",
                   api_key: "test-secret",
                   req_http_options: [plug: plug]
                 )
      end)

    assert log =~ "[info]"
    assert log =~ "AI API response"
    assert log =~ "logged-model"
    assert log =~ "total_tokens: 13"
    assert log =~ "duration_ms:"
    refute log =~ "Logged response"
    refute log =~ "test-secret"
  end

  test "returns errors for non-successful compatible endpoint responses" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"message" => "invalid API key"}})
    end

    log =
      capture_log(fn ->
        assert {:error, reason} =
                 LLM.generate("unauthorized-model", Context.new([Context.user("Hello")]),
                   endpoint: "https://ai.example/v1",
                   api_key: "bad-secret",
                   req_http_options: [plug: plug]
                 )

        assert reason =~ "401"
      end)

    assert log =~ "[warning]"
    assert log =~ "status: 401"
    assert log =~ "duration_ms:"
    refute log =~ "invalid API key"
    refute log =~ "bad-secret"
  end

  test "returns errors for malformed compatible endpoint responses" do
    plug = fn conn ->
      Req.Test.json(conn, %{"unexpected" => true})
    end

    log =
      capture_log(fn ->
        assert {:error, reason} =
                 LLM.generate("malformed-response-model", Context.new([Context.user("Hello")]),
                   endpoint: "https://ai.example/v1",
                   api_key: "test-secret",
                   req_http_options: [plug: plug]
                 )

        assert is_binary(reason)
      end)

    assert log =~ "[warning]"
    assert log =~ "malformed-response-model"
  end

  test "logs server API errors at error level" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"message" => "maintenance"}})
    end

    log =
      capture_log(fn ->
        assert {:error, reason} =
                 LLM.generate("unavailable-model", Context.new([Context.user("Hello")]),
                   endpoint: "https://ai.example/v1",
                   api_key: "test-secret",
                   req_http_options: [plug: plug]
                 )

        assert reason =~ "503"
      end)

    assert log =~ "[error]"
    assert log =~ "status: 503"
    refute log =~ "maintenance"
    refute log =~ "test-secret"
  end

  test "normalizes empty responses to an ellipsis" do
    assert LLM.normalize_response_text(nil) == "..."
    assert LLM.normalize_response_text("") == "..."
    assert LLM.normalize_response_text("   \n") == "..."
  end

  test "does not log exception messages containing response or credential data" do
    log =
      capture_log(fn ->
        assert {:error, _reason} =
                 LLM.generate("exception-model", Context.new([Context.user("private prompt")]),
                   endpoint: "https://ai.example/v1",
                   api_key: "private-api-key",
                   req_http_options: [plug: fn _conn -> raise "private provider response" end]
                 )
      end)

    assert log =~ "exception-model"
    assert log =~ "error_type: RuntimeError"
    refute log =~ "private provider response"
    refute log =~ "private-api-key"
    refute log =~ "private prompt"
  end

  test "keeps non-empty responses unchanged" do
    assert LLM.normalize_response_text("hello") == "hello"
  end

  test "trims leading and trailing response whitespace" do
    assert LLM.normalize_response_text(" \n hello there\t \r\n") == "hello there"
  end

  test "removes a weekday-prefixed first line" do
    for weekday <- ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday) do
      assert LLM.normalize_response_text("#{weekday}, July 17, 2026\nhello") == "hello"
    end

    assert LLM.normalize_response_text("Friday, 2026-07-17 10:16:44 \nFinalmente weekend.") ==
             "Finalmente weekend."

    assert LLM.normalize_response_text("Thursday, July 17, 2026\r\nhello\r\nthere") ==
             "hello\r\nthere"
  end

  test "removes the weekday line when preceded by invisible Unicode characters" do
    assert LLM.normalize_response_text(
             "\uFEFF\u200BFriday, 2026-07-17 10:16:44\u2028Finalmente weekend."
           ) == "Finalmente weekend."
  end

  test "removes a weekday after trimming leading whitespace" do
    assert LLM.normalize_response_text(" \nThursday, July 17, 2026\nhello ") == "hello"
  end

  test "only removes a weekday when it is followed by a comma on the first content line" do
    assert LLM.normalize_response_text("Thursday July 17, 2026\nhello") ==
             "Thursday July 17, 2026\nhello"

    assert LLM.normalize_response_text("hello\nThursday, July 17, 2026") ==
             "hello\nThursday, July 17, 2026"
  end

  test "normalizes a response containing only a weekday-prefixed line to an ellipsis" do
    assert LLM.normalize_response_text("Thursday, July 17, 2026") == "..."
  end

  defp chat_completion_response(content) do
    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion",
      "created" => 1_753_200_000,
      "model" => "compatible-model",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 8,
        "completion_tokens" => 5,
        "total_tokens" => 13
      }
    }
  end
end
