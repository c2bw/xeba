defmodule XebaWeb.ChatId do
  @moduledoc false

  def parse(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 -> id
      _ -> nil
    end
  end

  def parse(_value), do: nil
end
