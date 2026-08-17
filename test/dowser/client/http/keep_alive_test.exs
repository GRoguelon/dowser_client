defmodule Dowser.Client.HTTP.KeepAliveTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP
  alias Dowser.Client.Response
  alias Dowser.Client.TCPTestServer

  @body ~s({"ok":true})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@body)}\r\nConnection: keep-alive\r\n\r\n" <>
              @body

  # The server accepts exactly ONE connection and then closes its listener. It
  # serves two sequential requests on that single socket. If an adapter did not
  # keep the connection alive, its second request would try to open a fresh
  # connection and be refused — so two successful requests prove reuse.
  test "each adapter sends HTTP/1.1 and reuses one keep-alive connection" do
    for adapter <- adapters() do
      {port, server} = TCPTestServer.start_keep_alive(@response, 2)
      url = "http://127.0.0.1:#{port}/"

      first = adapter.request(:get, url, [], nil, [])
      second = adapter.request(:get, url, [], nil, [])

      assert match?({:ok, %Response{status: 200}}, first),
             "#{inspect(adapter)}: first request failed: #{inspect(first)}"

      assert match?({:ok, %Response{status: 200}}, second),
             "#{inspect(adapter)}: second request failed — connection not reused: #{inspect(second)}"

      requests = Task.await(server, 5000)

      assert length(requests) == 2,
             "#{inspect(adapter)}: expected 2 requests on one connection, got #{length(requests)}"

      assert Enum.all?(requests, &(&1.version == "HTTP/1.1")),
             "#{inspect(adapter)}: expected HTTP/1.1 request lines, got #{inspect(Enum.map(requests, & &1.version))}"
    end
  end

  defp adapters do
    [
      {HTTP.Httpc, true},
      {HTTP.Req, Code.ensure_loaded?(Req)},
      {HTTP.Hackney, Code.ensure_loaded?(:hackney)}
    ]
    |> Enum.filter(fn {_mod, available?} -> available? end)
    |> Enum.map(fn {mod, _} -> mod end)
  end
end
