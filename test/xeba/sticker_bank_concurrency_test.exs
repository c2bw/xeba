defmodule Xeba.StickerBankConcurrencyTest do
  use ExUnit.Case
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Xeba.Conversations
  alias Xeba.Conversations.{ChatSticker, Exchange}
  alias Xeba.Repo

  test "independent writers converge on one sticker identity" do
    chat_id = -9_000_000_000 - System.unique_integer([:positive])

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from s in ChatSticker, where: s.chat_id == ^chat_id)
        Repo.delete_all(from e in Exchange, where: e.chat_id == ^chat_id)
      end)
    end)

    workers = start_supervised!({Task.Supervisor, []})
    owner = self()

    tasks =
      for index <- 1..2 do
        Task.Supervisor.async_nolink(workers, fn ->
          send(owner, {:ready, self()})

          receive do
            :record ->
              Sandbox.unboxed_run(Repo, fn ->
                Conversations.create_from_message(
                  %ExironClient.Message{
                    req_id: "concurrent-#{chat_id}-#{index}",
                    chat_id: chat_id,
                    datatype: "file",
                    sticker_id: "file-#{index}",
                    file_unique_id: "same-stable-identity",
                    data: <<"RIFF", 0, 0, 0, 0, "WEBP", "shared bytes">>
                  },
                  "test"
                )
              end)
          end
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, worker}
      send(worker, :record)
    end

    for task <- tasks, do: assert({:ok, _} = Task.await(task))

    Sandbox.unboxed_run(Repo, fn ->
      [sticker] = Conversations.list_chat_stickers(chat_id)
      assert sticker.file_unique_id == "same-stable-identity"
      assert Enum.sort(sticker.sticker_ids) == ["file-1", "file-2"]
      assert length(Conversations.list_exchanges_for_chat(chat_id)) == 2
    end)
  end
end
