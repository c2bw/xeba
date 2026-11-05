defmodule Xeba.Telegram.MessageText do
  @doc "Returns message text or media captions, never the attachment bytes."
  def content(%{datatype: "text", data: data}) when is_binary(data), do: data

  def content(%{datatype: datatype} = message)
      when datatype in ["image", "file", "video", "audio", "sticker", "album"] do
    items = if datatype == "album", do: Map.get(message, :media_items) || [], else: []

    captions =
      [Map.get(message, :caption) | Enum.map(items, &Map.get(&1, :caption))]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if captions != [], do: Enum.join(captions, "\n\n")
  end

  def content(_message), do: nil

  def normalize(text) when is_binary(text) do
    text
    |> String.trim()
    |> then(&Regex.replace(~r/^\/ai(?:@\w+)?(?:\s+|$)/iu, &1, ""))
    |> String.trim()
  end

  def mentioned?(text, bot_name) when is_binary(text) and is_binary(bot_name) do
    case mention_regex(bot_name) do
      nil -> false
      regex -> Regex.match?(regex, text)
    end
  end

  def remove_mention(text, bot_name) when is_binary(text) and is_binary(bot_name) do
    case mention_regex(bot_name) do
      nil -> String.trim(text)
      regex -> regex |> Regex.replace(text, "") |> String.trim()
    end
  end

  defp mention_regex(bot_name) do
    name = bot_name |> String.trim() |> String.trim_leading("@")

    if name != "" do
      Regex.compile!("(?<![\\p{L}\\p{N}_@])@?#{Regex.escape(name)}(?![\\p{L}\\p{N}_])", "iu")
    end
  end
end
