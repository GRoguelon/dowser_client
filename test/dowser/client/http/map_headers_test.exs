defmodule Dowser.Client.HTTP.MapHeadersTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP
  alias Dowser.Client.Response
  alias Dowser.Client.TCPTestServer

  @body ~s({"ok":true})
  @response "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(@body)}\r\n\r\n" <> @body

  # Regression: headers given as a map must work on every adapter (hackney's
  # header parser only accepts a list of tuples, unlike Req / :httpc).
  test "every adapter accepts headers given as a map" do
    for adapter <- adapters() do
      {port, server} = TCPTestServer.start(@response)
      url = "http://127.0.0.1:#{port}/"

      assert {:ok, %Response{status: 200}} =
               adapter.request(:get, url, %{"X-Test" => "value"}, nil, []),
             "#{inspect(adapter)} rejected map headers"

      assert Task.await(server).headers["x-test"] == "value",
             "#{inspect(adapter)} did not send the map header"
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
