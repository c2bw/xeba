defmodule Xeba.Telegram.ExironTest do
  use ExUnit.Case, async: false

  alias Xeba.Telegram.Exiron

  test "SDK WebSocket reports identity, acknowledges completed work and notifies shutdown once" do
    parent = self()

    client =
      Exiron.new(base_url: server(:websocket), token: "test-token", client_id: "xeba-test")

    pid =
      start_poller(
        client: client,
        handler: fn message ->
          send(parent, {:handled, self(), message})
          receive do: (:complete -> :ok)
        end,
        on_connect: fn -> send(parent, :connected) end,
        on_disconnect: fn reason -> send(parent, {:disconnected, reason}) end
      )

    assert_receive {:headers, headers}, 1_000
    assert headers["x-exiron-sdk"] == "elixir"
    assert headers["x-exiron-sdk-version"] == ExironClient.Version.current()
    assert headers["authorization"] == "Bearer test-token"
    assert_receive :connected, 1_000
    assert_receive {:handled, worker, %ExironClient.Message{req_id: "one", data: "hello"}}, 1_000
    refute_receive {:ack, _}
    send(worker, :complete)
    assert_receive {:ack, %{"type" => "ack", "delivery_id" => "batch"}}, 1_000

    ref = Process.monitor(pid)
    assert :ok = stop_supervised(:connection)
    assert_receive {:disconnected, :shutdown}
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    refute_receive {:disconnected, _}
  end

  test "the same integration still supports HTTP polling" do
    parent = self()
    client = Exiron.new(base_url: server(:http), token: "test-token", client_id: "xeba-test")

    start_poller(
      client: client,
      transport: :http,
      interval_ms: 60_000,
      handler: fn _ -> :ok end,
      on_connect: fn -> send(parent, :connected) end
    )

    assert_receive {:headers, headers}, 1_000
    assert headers["x-exiron-sdk"] == "elixir"
    assert headers["x-exiron-sdk-version"] == ExironClient.Version.current()
    assert_receive :connected, 1_000
  end

  defp start_poller(opts) do
    # The transport fixture serves one connection and has no capabilities endpoint.
    opts = Keyword.put(opts, :runtime_reporting, false)
    start_supervised!(%{id: :connection, start: {Exiron, :start_poller, [opts]}})
  end

  defp server(transport) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    task =
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)

         try do
           headers = receive_headers(socket, "")
           send(parent, {:headers, headers})
           respond(socket, headers, transport, parent)
         after
           :gen_tcp.close(socket)
         end
       end}

    start_supervised!(task, id: make_ref(), restart: :temporary)

    "http://127.0.0.1:#{port}"
  end

  defp receive_headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
      |> String.split("\r\n\r\n", parts: 2)
      |> hd()
      |> String.split("\r\n")
      |> tl()
      |> Map.new(fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
      receive_headers(socket, buffer <> data)
    end
  end

  defp respond(socket, _headers, :http, _parent) do
    body = Jason.encode!(%{requests: []})

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\ncontent-length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])
  end

  defp respond(socket, headers, :websocket, parent) do
    accept =
      :crypto.hash(:sha, headers["sec-websocket-key"] <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      |> Base.encode64()

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: ",
        accept,
        "\r\n\r\n"
      ])

    :ok =
      :gen_tcp.send(
        socket,
        frame(%{type: "connected", protocol_version: "1.19", capabilities: []})
      )

    :ok =
      :gen_tcp.send(
        socket,
        frame(%{
          type: "messages",
          delivery_id: "batch",
          messages: [
            %{msgtype: "request", req_id: "one", datatype: "text", data: Base.encode64("hello")}
          ]
        })
      )

    {:ok, <<1::1, 0::3, 1::4, 1::1, length::7>>} = :gen_tcp.recv(socket, 2, 5_000)
    {:ok, mask} = :gen_tcp.recv(socket, 4, 5_000)
    {:ok, payload} = :gen_tcp.recv(socket, length, 5_000)

    decoded =
      payload
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(mask, rem(index, 4))) end)
      |> :binary.list_to_bin()
      |> Jason.decode!()

    send(parent, {:ack, decoded})
    receive do: (:stop -> :ok)
  end

  defp frame(value) do
    data = Jason.encode!(value)

    if byte_size(data) <= 125,
      do: <<0x81, byte_size(data), data::binary>>,
      else: <<0x81, 126, byte_size(data)::16, data::binary>>
  end
end
