defmodule Xeba.Conversations.OutgoingMessages do
  @moduledoc "Durable Telegram delivery identities and reply lookup."
  import Ecto.Query
  alias Xeba.Conversations.{Exchange, OutgoingMessage}
  alias Xeba.Repo

  def reply_target(%{service_id: service, chat_id: chat, reply_to_message_id: id} = message)
      when is_integer(service) and is_integer(chat) and is_integer(id) and id > 0 do
    sender = Map.get(message, :from) || %{}

    unless Map.get(sender, :is_bot, Map.get(sender, "is_bot", false)) do
      thread = Map.get(message, :message_thread_id)

      target =
        Repo.one(
          from m in OutgoingMessage,
            join: e in Exchange,
            on: e.id == m.exchange_id,
            select: {m, e.response_text, e.delivery_state},
            where: m.service_id == ^service and m.chat_id == ^chat and m.message_id == ^id,
            where: fragment("? IS NOT DISTINCT FROM ?", m.message_thread_id, ^thread)
        )

      case target do
        {outgoing, text, state} ->
          plan = state["plan"] || %{}

          text =
            if outgoing.part == "sticker_sent",
              do: "[sticker #{plan["emoji"]}]",
              else: text || plan["text"] || ""

          %{outgoing | text: text}

        nil ->
          nil
      end
    end
  end

  def reply_target(_message), do: nil

  def checkpoint(exchange, field, result) do
    Repo.transaction(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for receipt <- receipts(result),
            service = value(receipt, :service_id),
            chat = value(receipt, :chat_id),
            is_integer(service) and is_integer(chat) and chat == exchange.chat_id,
            is_nil(exchange.service_id) or exchange.service_id == service,
            id <- message_ids(receipt),
            is_integer(id) and id > 0 do
          %{
            exchange_id: exchange.id,
            service_id: service,
            chat_id: chat,
            message_id: id,
            message_thread_id: value(receipt, :message_thread_id),
            part: field,
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(OutgoingMessage, rows,
        on_conflict: :nothing,
        conflict_target: [:service_id, :chat_id, :message_id]
      )

      exchange
      |> Exchange.changeset(%{delivery_state: Map.put(exchange.delivery_state, field, true)})
      |> Repo.update!()
    end)
  end

  defp receipts(result) when is_map(result) do
    case value(result, :receipts) do
      receipts when is_list(receipts) -> Enum.filter(receipts, &is_map/1)
      _ -> []
    end
  end

  defp receipts(_result), do: []

  defp message_ids(receipt) do
    case value(receipt, :message_ids) do
      ids when is_list(ids) -> Enum.uniq(ids)
      _ -> []
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
