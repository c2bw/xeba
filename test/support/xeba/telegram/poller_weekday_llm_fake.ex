defmodule Xeba.Telegram.PollerWeekdayLLMFake do
  def generate(_model, _context, _opts) do
    {:ok, " \nThursday, July 17, 2026\nThe response body \t\n", %{}}
  end
end
