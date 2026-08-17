defmodule Dowser.Client.TCPTestServer do
  @moduledoc """
  Minimal one-shot raw-TCP HTTP server for HTTP-adapter integration tests.

  Every helper here binds to an OS-assigned port so tests can run
  concurrently without clashing; none of it understands HTTP beyond parsing
  a request line, headers and a `Content-Length`-sized body.
  """

  ## Public functions

  @doc """
  Starts a listening socket, accepts exactly one connection, reads one full
  HTTP request off it, and replies with `response` verbatim.

  Returns `{port, task}` — `task` (a `Task`) resolves to the parsed request
  (`%{method:, path:, version:, headers:, body:}`) once the client connects;
  `Task.await/1` it after making the request.
  """
  def start(response) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5000)
        request = read_request(socket)
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        request
      end)

    {port, server}
  end

  @doc """
  Like `start/1`, but accepts a single connection and serves `request_count`
  sequential requests on it, closing the listener immediately after
  accepting (so a second *connection* attempt is refused). Proves an
  adapter reuses a keep-alive connection instead of opening a fresh one for
  each request.

  Returns `{port, task}`; `task` resolves to a list of parsed requests.
  """
  def start_keep_alive(response, request_count) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5000)
        :gen_tcp.close(listen)

        requests =
          Enum.map(1..request_count, fn _ ->
            request = read_request(socket)
            :ok = :gen_tcp.send(socket, response)
            request
          end)

        :gen_tcp.close(socket)
        requests
      end)

    {port, server}
  end

  @doc """
  Starts a listening socket that never `accept/1`s a connection. A client's
  TCP handshake still completes immediately (the kernel backlog accepts the
  SYN), so `connect` succeeds and then the connection hangs forever waiting
  for a response — useful for proving a *receive*-timeout override fires
  quickly, without a test ever waiting out a real (multi-second) default.

  Registers `on_exit/1` to close the listener; must be called from within a
  test process.
  """
  def start_slow do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(listen) end)
    port
  end

  @doc "Returns a TCP port that is free at the moment of the call, then releases it."
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  ## Private functions

  defp read_request(socket) do
    raw = recv_until(socket, "", "\r\n\r\n")
    [head, rest] = String.split(raw, "\r\n\r\n", parts: 2)
    body = rest <> recv_exact(socket, content_length(head) - byte_size(rest))
    parse(head, body)
  end

  defp recv_until(socket, acc, marker) do
    if String.contains?(acc, marker) do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      recv_until(socket, acc <> data, marker)
    end
  end

  defp recv_exact(_socket, n) when n <= 0, do: ""

  defp recv_exact(socket, n) do
    {:ok, data} = :gen_tcp.recv(socket, n, 5000)
    data
  end

  defp content_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] ->
          if String.downcase(String.trim(k)) == "content-length",
            do: String.to_integer(String.trim(v))

        _ ->
          nil
      end
    end)
  end

  defp parse(head, body) do
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, path, version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(k)), String.trim(v)}
      end)

    %{method: method, path: path, version: version, headers: headers, body: body}
  end
end
