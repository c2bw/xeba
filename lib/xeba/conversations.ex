defmodule Xeba.Conversations do
  import Ecto.Query

  alias Xeba.Conversations.{
    AutonomousChannelSetting,
    ChatSticker,
    DatabaseTextReplacement,
    Exchange,
    TelegramChat
  }

  alias Xeba.Repo
  alias Xeba.Telegram.{MessageText, Prompt}

  @topic "exchanges"
  @editable_exchange_statuses ~w(completed observed no_answer failed)
  @replaceable_exchange_fields [
    :sender_first_name,
    :sender_last_name,
    :sender_username,
    :request_text,
    :response_text,
    :error
  ]

  def subscribe, do: Phoenix.PubSub.subscribe(Xeba.PubSub, @topic)

  def list_exchanges_for_chat(chat_id, limit \\ 100) do
    Exchange
    |> where([exchange], exchange.chat_id == ^chat_id)
    |> order_by([exchange], desc: exchange.inserted_at, desc: exchange.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_display_exchanges(chat_id \\ nil, count \\ 100) do
    query = if is_nil(chat_id), do: Exchange, else: where(Exchange, [e], e.chat_id == ^chat_id)

    query
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^count)
    |> select_display_exchange()
    |> Repo.all()
  end

  defp select_display_exchange(query) do
    fields = Exchange.__schema__(:fields) -- [:sticker_data, :delivery_state]

    query
    |> select([e], struct(e, ^fields))
    |> select_merge([e], %{
      sticker_data_prefix: fragment("substring(? from 1 for 12)", e.sticker_data)
    })
  end

  def rolling_token_usage(now \\ DateTime.utc_now()) do
    minute_cutoff = DateTime.add(now, -1, :minute)
    hour_cutoff = DateTime.add(now, -1, :hour)
    day_cutoff = DateTime.add(now, -1, :day)

    Exchange
    |> where(
      [exchange],
      not is_nil(exchange.total_tokens) and exchange.tokens_used_at >= ^day_cutoff
    )
    |> select([exchange], %{
      minute:
        fragment(
          "COALESCE(SUM(?) FILTER (WHERE ? >= ?), 0)",
          exchange.total_tokens,
          exchange.tokens_used_at,
          ^minute_cutoff
        ),
      hour:
        fragment(
          "COALESCE(SUM(?) FILTER (WHERE ? >= ?), 0)",
          exchange.total_tokens,
          exchange.tokens_used_at,
          ^hour_cutoff
        ),
      day: fragment("COALESCE(SUM(?), 0)", exchange.total_tokens)
    })
    |> Repo.one!()
  end

  @transcript_page_size 100

  def transcript_calendar(chat_id, through_day \\ nil) do
    query = transcript_query(chat_id)

    query =
      if through_day,
        do:
          where(
            query,
            [e],
            e.inserted_at <
              fragment(
                "((?::date + 1)::timestamp AT TIME ZONE 'Europe/Rome') AT TIME ZONE 'UTC'",
                type(^through_day, :date)
              )
          ),
        else: query

    entries =
      query
      |> group_by(
        [e],
        fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Rome')::date", e.inserted_at)
      )
      |> select([e], %{
        day:
          type(
            fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Rome')::date", e.inserted_at),
            :date
          ),
        count:
          sum(
            fragment(
              "CASE WHEN ? = 'autonomous' THEN 0 ELSE 1 END + CASE WHEN ? IS NOT NULL AND ? != '' THEN 1 ELSE 0 END",
              e.msgtype,
              e.response_text,
              e.response_text
            )
          )
      })
      |> order_by([e],
        desc: fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Rome')::date", e.inserted_at)
      )
      |> having(
        [e],
        sum(
          fragment(
            "CASE WHEN ? = 'autonomous' THEN 0 ELSE 1 END + CASE WHEN ? IS NOT NULL AND ? != '' THEN 1 ELSE 0 END",
            e.msgtype,
            e.response_text,
            e.response_text
          )
        ) > 0
      )
      |> limit(31)
      |> Repo.all()

    %{days: Enum.take(entries, 30), older?: length(entries) > 30}
  end

  def transcript_page(chat_id, day, page \\ 1) do
    query =
      transcript_query(chat_id)
      |> where(
        [e],
        e.inserted_at >=
          fragment(
            "(?::date::timestamp AT TIME ZONE 'Europe/Rome') AT TIME ZONE 'UTC'",
            type(^day, :date)
          )
      )
      |> where(
        [e],
        e.inserted_at <
          fragment(
            "((?::date + 1)::timestamp AT TIME ZONE 'Europe/Rome') AT TIME ZONE 'UTC'",
            type(^day, :date)
          )
      )

    pages =
      max(
        1,
        div(Repo.aggregate(query, :count) + @transcript_page_size - 1, @transcript_page_size)
      )

    page = page |> max(1) |> min(pages)

    exchanges =
      query
      |> order_by([e], asc: e.inserted_at, asc: e.id)
      |> limit(@transcript_page_size)
      |> offset(^((page - 1) * @transcript_page_size))
      |> select_display_exchange()
      |> Repo.all()

    %{exchanges: exchanges, page: page, pages: pages}
  end

  defp transcript_query(chat_id) do
    from e in Exchange,
      where:
        e.chat_id == ^chat_id and
          (e.msgtype != "autonomous" or (not is_nil(e.response_text) and e.response_text != ""))
  end

  def list_chats do
    activity_query =
      Exchange
      |> where([exchange], not is_nil(exchange.chat_id))
      |> group_by([exchange], exchange.chat_id)
      |> select([exchange], %{
        chat_id: exchange.chat_id,
        exchange_count: count(exchange.id),
        last_message_at: max(exchange.inserted_at)
      })

    activity_query
    |> subquery()
    |> join(:left, [activity], chat in TelegramChat, on: chat.chat_id == activity.chat_id)
    |> select([activity, chat], %{
      chat_id: activity.chat_id,
      chat_name: chat.name,
      exchange_count: activity.exchange_count,
      last_message_at: activity.last_message_at
    })
    |> order_by([activity], desc: activity.last_message_at)
    |> Repo.all()
  end

  def chat_name(chat_id) when is_integer(chat_id) do
    TelegramChat
    |> where([chat], chat.chat_id == ^chat_id)
    |> select([chat], chat.name)
    |> Repo.one()
  end

  def chat_name(_chat_id), do: nil

  def remember_chat_name(chat_id, name) when is_integer(chat_id) do
    case normalize_chat_name(name) do
      nil ->
        :ignore

      name ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        %TelegramChat{}
        |> TelegramChat.changeset(%{chat_id: chat_id, name: name})
        |> Repo.insert(
          on_conflict: [set: [name: name, updated_at: now]],
          conflict_target: [:chat_id],
          returning: true
        )
        |> broadcast_chat()
    end
  end

  def remember_chat_name(_chat_id, _name), do: :ignore

  def remember_chat_names_from_status(status) when is_map(status) do
    seen_chat_ids =
      status
      |> map_value(:chats)
      |> list_value()
      |> remember_status_chat_names(MapSet.new())

    status
    |> map_value(:membership_events)
    |> list_value()
    |> remember_status_chat_names(seen_chat_ids)

    :ok
  end

  def remember_chat_names_from_status(_status), do: :ok

  def get_by_req_id(req_id), do: Repo.get_by(Exchange, req_id: req_id)

  def get_by_message(message) do
    cond do
      is_binary(message.req_id) ->
        get_by_req_id(message.req_id)

      is_integer(message.message_id) ->
        Repo.get_by(Exchange,
          service_id: message.service_id,
          chat_id: message.chat_id,
          message_id: message.message_id,
          msgtype: message.msgtype
        )

      true ->
        nil
    end
  end

  def count_chat_messages(chat_id) do
    Exchange
    |> where([exchange], exchange.chat_id == ^chat_id and exchange.msgtype != "autonomous")
    |> Repo.aggregate(:count)
  end

  def chat_message_counts do
    Exchange
    |> where([e], not is_nil(e.chat_id) and e.msgtype != "autonomous")
    |> group_by([e], e.chat_id)
    |> select([e], {e.chat_id, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  def preview_database_text_replacement(from) when is_binary(from) do
    with {:ok, from} <- validate_replacement_source(from) do
      query = replacement_match_query(from)

      if Repo.exists?(
           where(query, [exchange], exchange.status not in ^@editable_exchange_statuses)
         ) do
        {:error, :delivery_in_progress}
      else
        {:ok, Repo.aggregate(query, :count)}
      end
    end
  end

  def preview_database_text_replacement(_from), do: {:error, :invalid_text}

  def replace_database_text(from, to) do
    case replace_database_text_with_undo(from, to) do
      {:ok, %{updated_rows: updated_rows}} -> {:ok, updated_rows}
      error -> error
    end
  end

  def replace_database_text_with_undo(from, to)
      when is_binary(from) and is_binary(to) do
    with {:ok, from} <- validate_replacement_source(from) do
      result =
        Repo.transaction(fn ->
          exchanges =
            from
            |> replacement_match_query()
            |> order_by([exchange], asc: exchange.id)
            |> lock("FOR UPDATE")
            |> Repo.all()

          if Enum.any?(exchanges, &(&1.status not in @editable_exchange_statuses)) do
            Repo.rollback(:delivery_in_progress)
          end

          updated_rows =
            case Repo.query(replace_database_text_sql(), [
                   Regex.escape(from),
                   escape_regexp_replacement(to),
                   from
                 ]) do
              {:ok, %{num_rows: updated_rows}} -> updated_rows
              {:error, _error} -> Repo.rollback(:replacement_failed)
            end

          if updated_rows != length(exchanges) do
            Repo.rollback(:replacement_changed_during_update)
          end

          snapshots =
            Enum.map(exchanges, fn original ->
              replacement_snapshot(original, Repo.reload!(original))
            end)

          operation =
            if updated_rows > 0 do
              %DatabaseTextReplacement{}
              |> DatabaseTextReplacement.changeset(%{
                source_text: from,
                replacement_text: to,
                affected_rows: updated_rows,
                snapshot: %{"version" => 2, "rows" => snapshots}
              })
              |> Repo.insert!()
            end

          %{updated_rows: updated_rows, operation: operation}
        end)

      case result do
        {:ok, replacement} ->
          broadcast_database_text_change(from, to)
          {:ok, replacement}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def replace_database_text_with_undo(_from, _to), do: {:error, :invalid_text}

  def latest_undoable_database_text_replacement do
    DatabaseTextReplacement
    |> where([replacement], is_nil(replacement.undone_at))
    |> order_by([replacement], desc: replacement.inserted_at, desc: replacement.id)
    |> limit(1)
    |> Repo.one()
  end

  def undo_database_text_replacement(%DatabaseTextReplacement{id: id}),
    do: undo_database_text_replacement(id)

  def undo_database_text_replacement(id) when is_integer(id) do
    result =
      Repo.transaction(fn ->
        operation =
          DatabaseTextReplacement
          |> where([replacement], replacement.id == ^id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        cond do
          is_nil(operation) ->
            Repo.rollback(:replacement_not_found)

          not is_nil(operation.undone_at) ->
            Repo.rollback(:already_undone)

          operation.snapshot["version"] != 2 ->
            Repo.rollback(:legacy_snapshot)

          true ->
            rows = Map.get(operation.snapshot, "rows", [])
            Enum.each(rows, &restore_replacement_snapshot!/1)

            operation =
              operation
              |> Ecto.Changeset.change(undone_at: DateTime.utc_now())
              |> Repo.update!()

            %{restored_rows: length(rows), operation: operation}
        end
      end)

    case result do
      {:ok, replacement} ->
        broadcast_database_text_change(
          replacement.operation.replacement_text,
          replacement.operation.source_text
        )

        {:ok, replacement}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def undo_database_text_replacement(_id), do: {:error, :invalid_replacement}

  def autonomous_enabled?(chat_id) do
    autonomous_channel_setting(chat_id).enabled
  end

  def system_prompt_template(chat_id) when is_integer(chat_id) do
    autonomous_channel_setting(chat_id).system_prompt || Prompt.default_template()
  end

  def update_system_prompt(chat_id, prompt)
      when is_integer(chat_id) and is_binary(prompt) do
    if String.trim(prompt) == "" do
      {:error, :blank_system_prompt}
    else
      update_autonomous_channel_setting(chat_id, %{system_prompt: prompt})
    end
  end

  def update_system_prompt(_chat_id, _prompt), do: {:error, :invalid_system_prompt}

  def reset_system_prompt(chat_id) when is_integer(chat_id) do
    update_autonomous_channel_setting(chat_id, %{system_prompt: nil})
  end

  def autonomous_settings do
    AutonomousChannelSetting
    |> Repo.all()
    |> Map.new(&{&1.chat_id, &1})
  end

  def autonomous_channel_setting(chat_id) when is_integer(chat_id) do
    Repo.get_by(AutonomousChannelSetting, chat_id: chat_id) ||
      %AutonomousChannelSetting{chat_id: chat_id}
  end

  def set_autonomous_enabled(chat_id, enabled)
      when is_integer(chat_id) and is_boolean(enabled) do
    chat_id
    |> autonomous_channel_setting()
    |> AutonomousChannelSetting.changeset(%{enabled: enabled})
    |> Repo.insert_or_update()
    |> broadcast_autonomous_setting()
  end

  def change_autonomous_channel_setting(%AutonomousChannelSetting{} = setting, attrs \\ %{}) do
    AutonomousChannelSetting.changeset(setting, attrs)
  end

  def update_autonomous_channel_setting(chat_id, attrs) when is_integer(chat_id) do
    chat_id
    |> autonomous_channel_setting()
    |> AutonomousChannelSetting.changeset(attrs)
    |> Repo.insert_or_update()
    |> broadcast_autonomous_setting()
  end

  def retryable_autonomous_delivery_ids(max_attempts) do
    Exchange
    |> where([e], e.msgtype == "autonomous" and e.status in ["pending", "reply_failed"])
    |> where([e], fragment("jsonb_exists(?, 'autonomous_attempts')", e.delivery_state))
    |> where(
      [e],
      e.status == "pending" or
        fragment(
          "COALESCE((?->>'autonomous_attempts')::integer, 0) < ?",
          e.delivery_state,
          ^max_attempts
        )
    )
    |> select([e], e.id)
    |> Repo.all()
  end

  def create_autonomous(chat_id, model, delivery_state \\ %{}) do
    %Exchange{}
    |> Exchange.changeset(%{
      msgtype: "autonomous",
      delivery_state: delivery_state,
      chat_id: chat_id,
      datatype: "text",
      model: model,
      status: "pending"
    })
    |> Repo.insert()
    |> broadcast()
  end

  def create_from_message(message, model, delivery_state \\ %{}) do
    _ = remember_chat_name(message.chat_id, message_chat_name(message))
    text = MessageText.content(message)

    attrs = %{
      delivery_state: delivery_state,
      req_id: message.req_id,
      msgtype: message.msgtype || "request",
      message_id: message.message_id,
      reply_to_message_id: message.reply_to_message_id,
      message_thread_id: message.message_thread_id,
      service_id: message.service_id,
      chat_id: message.chat_id,
      sender_id: sender_value(message.from, :id),
      sender_is_bot: sender_value(message.from, :is_bot),
      sender_first_name: sender_value(message.from, :first_name),
      sender_last_name: sender_value(message.from, :last_name),
      sender_username: sender_value(message.from, :username),
      sender_language_code: sender_value(message.from, :language_code),
      datatype: message.datatype,
      sticker_id: sticker_id(message),
      file_unique_id: message.file_unique_id,
      sticker_emoji: message.sticker_emoji,
      emoji_list: message.emoji_list,
      sticker_data: sticker_data(message),
      request_text: if(text, do: MessageText.normalize(text)),
      model: model,
      status: "pending"
    }

    Repo.transaction(fn ->
      case %Exchange{} |> Exchange.changeset(attrs) |> Repo.insert() do
        {:ok, exchange} ->
          case Xeba.Conversations.StickerBank.record(exchange) do
            {:ok, _sticker} -> exchange
            :ignore -> exchange
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> broadcast()
  end

  def update_exchange(%Exchange{} = exchange, attrs) do
    exchange
    |> Exchange.changeset(attrs)
    |> Repo.update()
    |> broadcast()
  end

  def reply_target(message), do: Xeba.Conversations.OutgoingMessages.reply_target(message)

  def checkpoint_delivery(exchange, field, result) do
    Xeba.Conversations.OutgoingMessages.checkpoint(exchange, field, result) |> broadcast()
  end

  def recent_history(chat_id, limit \\ 20) do
    Exchange
    |> where(
      [exchange],
      exchange.chat_id == ^chat_id and exchange.status in ["completed", "observed"]
    )
    |> where(
      [exchange],
      not is_nil(exchange.request_text) or
        not is_nil(exchange.sticker_id) or
        not is_nil(exchange.sticker_emoji) or
        (exchange.msgtype == "autonomous" and not is_nil(exchange.response_text))
    )
    |> order_by([exchange], desc: exchange.completed_at, desc: exchange.id)
    |> limit(^limit)
    |> select_display_exchange()
    |> Repo.all()
    |> Enum.reverse()
  end

  @sticker_page_size 24

  def chat_exists?(chat_id),
    do: Repo.exists?(from exchange in Exchange, where: exchange.chat_id == ^chat_id)

  def sticker_page(chat_id, emoji \\ "", page \\ 1) do
    base = from sticker in ChatSticker, where: sticker.chat_id == ^chat_id
    total = Repo.aggregate(base, :count)
    query = if emoji == "", do: base, else: sticker_emoji_query(base, emoji)
    matched = if emoji == "", do: total, else: Repo.aggregate(query, :count)
    pages = max(1, div(matched + @sticker_page_size - 1, @sticker_page_size))
    page = page |> max(1) |> min(pages)

    stickers =
      query
      |> order_by([s], desc: s.last_seen_at, desc: s.id)
      |> limit(@sticker_page_size)
      |> offset(^((page - 1) * @sticker_page_size))
      |> select([s], %{
        id: s.id,
        chat_id: s.chat_id,
        sticker_id: s.sticker_id,
        file_unique_id: s.file_unique_id,
        emoji: s.emoji,
        emoji_list: s.emoji_list,
        last_seen_at: s.last_seen_at,
        data_prefix: fragment("substring(? from 1 for 12)", s.data)
      })
      |> Repo.all()

    %{stickers: stickers, total: total, matched: matched, page: page, pages: pages}
  end

  def get_sticker_media(chat_id, id) do
    Repo.one(
      from s in ChatSticker,
        where: s.id == ^id and s.chat_id == ^chat_id,
        select: %{data: s.data}
    )
  end

  def get_exchange_sticker_media(chat_id, id) do
    Repo.one(
      from e in Exchange,
        where: e.id == ^id and e.chat_id == ^chat_id,
        select: %{data: e.sticker_data}
    )
  end

  def sticker_media_type(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: :image
  def sticker_media_type(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>), do: :video
  def sticker_media_type(<<0x1F, 0x8B, _rest::binary>>), do: :unsupported_animation
  def sticker_media_type(_data), do: nil

  def sticker_candidates_for_emoji(chat_id, emoji) do
    ChatSticker
    |> where([s], s.chat_id == ^chat_id)
    |> sticker_emoji_query(emoji)
    |> order_by([s], desc: s.last_seen_at, desc: s.id)
    |> limit(100)
    |> select([s], map(s, [:id, :chat_id, :sticker_id, :emoji, :emoji_list]))
    |> Repo.all()
  end

  defp sticker_emoji_query(query, emoji) do
    where(query, [s], fragment("? = ANY(?)", ^emoji, s.emoji_list) or s.emoji == ^emoji)
  end

  def list_chat_stickers(chat_id) when is_integer(chat_id) do
    ChatSticker
    |> where([sticker], sticker.chat_id == ^chat_id)
    |> order_by([sticker], desc: sticker.last_seen_at, desc: sticker.id)
    |> Repo.all()
  end

  def list_chat_stickers_for_emoji(chat_id, emoji)
      when is_integer(chat_id) and is_binary(emoji) do
    ChatSticker
    |> where(
      [sticker],
      sticker.chat_id == ^chat_id and
        (fragment("? = ANY(?)", ^emoji, sticker.emoji_list) or sticker.emoji == ^emoji)
    )
    |> order_by([sticker], desc: sticker.last_seen_at, desc: sticker.id)
    |> Repo.all()
  end

  defp replace_database_text_sql do
    set_clauses =
      Enum.map_join(@replaceable_exchange_fields, ", ", fn field ->
        column = Atom.to_string(field)
        ~s|"#{column}" = regexp_replace("#{column}", $1, $2, 'gi')|
      end)

    where_clauses =
      Enum.map_join(@replaceable_exchange_fields, " OR ", fn field ->
        column = Atom.to_string(field)
        ~s|strpos(lower("#{column}"), lower($3)) > 0|
      end)

    "UPDATE exchanges SET #{set_clauses} WHERE #{where_clauses}"
  end

  defp replacement_match_query(from) do
    condition =
      Enum.reduce(@replaceable_exchange_fields, dynamic(false), fn field_name, condition ->
        dynamic(
          [exchange],
          ^condition or
            fragment(
              "strpos(lower(?), lower(?)) > 0",
              field(exchange, ^field_name),
              ^from
            )
        )
      end)

    where(Exchange, ^condition)
  end

  defp replacement_snapshot(before, after_exchange) do
    fields =
      @replaceable_exchange_fields
      |> Enum.filter(&(Map.get(before, &1) != Map.get(after_exchange, &1)))
      |> Map.new(fn field ->
        {Atom.to_string(field),
         %{"before" => Map.get(before, field), "after" => Map.get(after_exchange, field)}}
      end)

    %{"id" => before.id, "fields" => fields}
  end

  defp restore_replacement_snapshot!(%{"id" => id, "fields" => fields}) do
    exchange =
      Repo.one(from exchange in Exchange, where: exchange.id == ^id, lock: "FOR UPDATE") ||
        Repo.rollback(:exchange_missing)

    if exchange.status not in @editable_exchange_statuses,
      do: Repo.rollback(:delivery_in_progress)

    attrs =
      Map.new(fields, fn {name, values} ->
        field =
          Enum.find(@replaceable_exchange_fields, &(Atom.to_string(&1) == name)) ||
            Repo.rollback(:restore_conflict)

        if Map.get(exchange, field) != values["after"], do: Repo.rollback(:restore_conflict)
        {field, values["before"]}
      end)

    case exchange |> Exchange.changeset(attrs) |> Repo.update() do
      {:ok, exchange} -> exchange
      {:error, _changeset} -> Repo.rollback(:restore_conflict)
    end
  end

  defp validate_replacement_source(from) do
    case String.trim(from) do
      "" -> {:error, :blank_source}
      from -> {:ok, from}
    end
  end

  defp escape_regexp_replacement(replacement) do
    String.replace(replacement, "\\", "\\\\")
  end

  defp broadcast_database_text_change(from, to) do
    Phoenix.PubSub.broadcast(Xeba.PubSub, @topic, {:database_text_replaced, from, to})
  end

  defp broadcast({:ok, exchange} = result) do
    Phoenix.PubSub.broadcast(Xeba.PubSub, @topic, {:exchange_updated, exchange})
    result
  end

  defp broadcast(result), do: result

  defp broadcast_autonomous_setting({:ok, setting} = result) do
    Phoenix.PubSub.broadcast(Xeba.PubSub, @topic, {:autonomous_setting_updated, setting})
    result
  end

  defp broadcast_autonomous_setting(result), do: result

  defp broadcast_chat({:ok, chat} = result) do
    Phoenix.PubSub.broadcast(Xeba.PubSub, @topic, {:chat_updated, chat})
    result
  end

  defp broadcast_chat(result), do: result

  defp sender_value(sender, key) when is_map(sender) do
    case Map.fetch(sender, key) do
      {:ok, value} -> value
      :error -> Map.get(sender, Atom.to_string(key))
    end
  end

  defp sender_value(_sender, _key), do: nil

  defp message_chat_name(message) do
    chat = map_value(message, :chat)
    sender = map_value(message, :from)

    [
      map_value(message, :chat_title),
      map_value(message, :chat_name),
      map_value(chat, :title),
      person_name(chat),
      username_name(chat),
      private_chat_person_name(message, sender),
      private_chat_username(message, sender)
    ]
    |> Enum.find_value(&normalize_chat_name/1)
  end

  defp private_chat_person_name(message, sender) do
    if map_value(message, :chat_id) == map_value(sender, :id), do: person_name(sender)
  end

  defp private_chat_username(message, sender) do
    if map_value(message, :chat_id) == map_value(sender, :id), do: username_name(sender)
  end

  defp person_name(person) when is_map(person) do
    [map_value(person, :first_name), map_value(person, :last_name)]
    |> Enum.map(&normalize_chat_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp person_name(_person), do: nil

  defp username_name(person) when is_map(person) do
    case normalize_chat_name(map_value(person, :username)) do
      nil -> nil
      "@" <> _username = name -> name
      username -> "@#{username}"
    end
  end

  defp username_name(_person), do: nil

  defp remember_status_chat_names(entries, seen_chat_ids) do
    Enum.reduce(entries, seen_chat_ids, fn entry, seen_chat_ids ->
      chat_id = map_value(entry, :chat_id) || map_value(entry, :id)

      chat_name =
        [
          map_value(entry, :chat_title),
          map_value(entry, :title),
          map_value(entry, :chat_name),
          map_value(entry, :name)
        ]
        |> Enum.find_value(&normalize_chat_name/1)

      if is_integer(chat_id) and is_binary(chat_name) and
           not MapSet.member?(seen_chat_ids, chat_id) do
        _ = remember_chat_name(chat_id, chat_name)
        MapSet.put(seen_chat_ids, chat_id)
      else
        seen_chat_ids
      end
    end)
  end

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_value(_map, _key), do: nil

  defp normalize_chat_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      name -> name
    end
  end

  defp normalize_chat_name(_name), do: nil

  defp sticker_id(%{sticker_id: sticker_id}) when is_binary(sticker_id) and sticker_id != "",
    do: sticker_id

  defp sticker_id(%{data: data, datatype: "sticker"}) when is_binary(data) and data != "",
    do: data

  defp sticker_id(_message), do: nil

  defp sticker_data(%{data: data, datatype: datatype, sticker_id: id, sticker_emoji: emoji})
       when is_binary(data) and data != "" and datatype != "sticker" and
              ((is_binary(id) and id != "") or (is_binary(emoji) and emoji != "")) do
    data
  end

  defp sticker_data(_message), do: nil
end
