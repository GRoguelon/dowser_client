defmodule Dowser.Client.TLSTestServer do
  @moduledoc """
  Minimal one-shot HTTPS server for `Dowser.Client.HTTP.SSL` integration tests.

  `certificates/0` generates a throw-away CA and server certificate (issued for
  `search.internal`, never for the `127.0.0.1` the test actually connects to,
  so hostname verification has something real to reject). `start/2` serves one
  request over TLS with them.
  """

  ## Public functions

  @doc """
  Generates a self-signed chain, returning
  `%{server: server_ssl_opts, cacerts: [der]}`.

  Key generation is slow enough to be worth doing once per test module
  (`setup_all`), not once per test.
  """
  def certificates(sans \\ [dNSName: ~c"search.internal"]) do
    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: key()],
          intermediates: [],
          peer: [
            key: key(),
            extensions: [
              # subjectAltName, so the certificate has an identity to check
              # against — a cert with none is rejected outright, which would
              # not tell verify_hostname: false apart from verify: false.
              {:Extension, {2, 5, 29, 17}, false, sans}
            ]
          ]
        },
        client_chain: %{root: [key: key()], intermediates: [], peer: [key: key()]}
      })

    %{server: Keyword.take(server, [:cert, :key, :cacerts]), cacerts: server[:cacerts]}
  end

  @doc """
  Starts a TLS listener with `certificates/0`'s `:server` options, accepts
  exactly one connection, reads one HTTP request and replies with `response`.

  Returns `{port, task}`; `task` resolves to the parsed request, or
  `{:error, reason}` when the handshake never completed (which is the point of
  the verification tests). Registers `on_exit/1` cleanup, so it must be called
  from a test process.
  """
  def start(response, server_opts) do
    {:ok, listen} =
      :ssl.listen(0, [:binary, {:active, false}, {:reuseaddr, true}] ++ server_opts)

    {:ok, {_address, port}} = :ssl.sockname(listen)
    ExUnit.Callbacks.on_exit(fn -> :ssl.close(listen) end)

    server =
      Task.async(fn ->
        with {:ok, socket} <- :ssl.transport_accept(listen, 5_000),
             {:ok, socket} <- :ssl.handshake(socket, 5_000) do
          request = read_request(socket)
          :ok = :ssl.send(socket, response)
          :ssl.close(socket)

          request
        end
      end)

    {port, server}
  end

  ## Private functions

  defp key, do: :public_key.generate_key({:rsa, 2048, 65_537})

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
      {:ok, data} = :ssl.recv(socket, 0, 5_000)

      recv_until(socket, acc <> data, marker)
    end
  end

  defp recv_exact(_socket, n) when n <= 0, do: ""

  defp recv_exact(socket, n) do
    {:ok, data} = :ssl.recv(socket, n, 5_000)

    data
  end

  defp content_length(head) do
    head |> String.split("\r\n") |> Enum.find_value(0, &content_length_header/1)
  end

  defp content_length_header(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> content_length_value(name, value)
      _other -> nil
    end
  end

  defp content_length_value(name, value) do
    if String.downcase(String.trim(name)) == "content-length" do
      String.to_integer(String.trim(value))
    end
  end

  defp parse(head, body) do
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, path, version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)

        {String.downcase(String.trim(key)), String.trim(value)}
      end)

    %{method: method, path: path, version: version, headers: headers, body: body}
  end
end
