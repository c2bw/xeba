defmodule Xeba.Telegram.MessageTextTest do
  use ExUnit.Case, async: true

  alias Xeba.Telegram.MessageText

  test "extracts media captions without exposing binary attachments" do
    for datatype <- ["image", "file", "video", "audio", "sticker"] do
      message = %ExironClient.Message{datatype: datatype, data: <<255, 0>>, caption: " dinner "}
      assert MessageText.content(message) == "dinner"
      assert MessageText.content(%{message | caption: nil}) == nil
      assert MessageText.content(%{message | caption: " \n "}) == nil
    end
  end

  test "collects album item captions and avoids repeating the envelope caption" do
    message = %ExironClient.Message{
      datatype: "album",
      caption: "first",
      media_items: [
        %ExironClient.MediaItem{datatype: "image", data: <<255>>, caption: " first "},
        %ExironClient.MediaItem{datatype: "file", data: <<0>>, caption: "second"},
        %ExironClient.MediaItem{datatype: "image", data: <<255>>, caption: nil}
      ]
    }

    assert MessageText.content(message) == "first\n\nsecond"
    assert MessageText.content(%{message | caption: nil, media_items: []}) == nil
  end

  test "keeps text messages unchanged and ignores callback data" do
    assert MessageText.content(%ExironClient.Message{datatype: "text", data: " /ai hello "}) ==
             " /ai hello "

    assert MessageText.content(%ExironClient.Message{datatype: "callback", data: "xeba"}) == nil
  end

  test "removes the ai command prefix" do
    assert MessageText.normalize("/ai hello") == "hello"
    assert MessageText.normalize("/ai") == ""
    assert MessageText.normalize("/ai@xeba_bot explain this") == "explain this"
  end

  test "trims leading and trailing whitespace" do
    assert MessageText.normalize(" \n hello there\t ") == "hello there"
    assert MessageText.normalize(" \n /ai explain this \r\n") == "explain this"
  end

  test "does not remove ai text that is not a command prefix" do
    assert MessageText.normalize("hello /ai world") == "hello /ai world"
    assert MessageText.normalize("/airplane") == "/airplane"
  end

  test "detects and removes the configured bot mention" do
    assert MessageText.mentioned?("could you help, @Xeba?", "xeba")
    assert MessageText.mentioned?("@xeba_bot help", "@xeba_bot")
    assert MessageText.mentioned?("hey @ANDREBOT, are you there?", "andrebot")
    assert MessageText.mentioned?("andrebot?", "andrebot")
    refute MessageText.mentioned?("hello @someone", "xeba")

    assert MessageText.remove_mention("could you help, @Xeba?", "xeba") == "could you help, ?"

    assert MessageText.remove_mention("hey @ANDREBOT, are you there?", "@andrebot") ==
             "hey , are you there?"

    assert MessageText.remove_mention("andrebot?", "andrebot") == "?"
  end

  test "does not match another username, an email, or a word containing the bot name" do
    for text <- ["@xeba_other hello", "prefixxebasuffix", "email@xeba", "xeba2", "@someone_xeba"] do
      refute MessageText.mentioned?(text, "xeba")
      assert MessageText.remove_mention(text, "xeba") == text
    end

    refute MessageText.mentioned?("anything", " ")
    assert MessageText.remove_mention("hello", "@") == "hello"
    assert MessageText.mentioned?("Hello, @XEBA!", "xeba")
  end
end
