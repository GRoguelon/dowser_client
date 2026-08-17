defmodule Dowser.Client.HTTP.HttpcTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP
  alias Dowser.Client.Response
  alias Dowser.Client.TCPTestServer

  @body ~s({"ok":true})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@body)}\r\n\r\n" <>
              @body

  test "performs a GET and normalizes the response" do
    {port, server} = TCPTestServer.start(@response)
    url = "http://127.0.0.1:#{port}/_search"

    assert {:ok, %Response{status: 200, body: body, headers: headers}} =
             HTTP.Httpc.request(:get, url, [{"accept", "application/json"}], nil, [])

    assert body == @body
    assert headers["content-type"] == "application/json"

    req = Task.await(server)
    assert req.method == "GET"
    assert req.path == "/_search"
    assert req.headers["accept"] == "application/json"
  end

  test "sends a request body with a content-type header" do
    {port, server} = TCPTestServer.start(@response)
    url = "http://127.0.0.1:#{port}/_search"
    body = ~s({"query":{"match_all":{}}})

    assert {:ok, %Response{status: 200}} =
             HTTP.Httpc.request(:post, url, [{"content-type", "application/json"}], body, [])

    req = Task.await(server)
    assert req.method == "POST"
    assert req.body == body
    assert req.headers["content-type"] == "application/json"
  end

  # `:httpc`'s request tuple has no body slot for GET/HEAD/etc., so a body
  # given for one of those methods must fail loudly instead of being
  # silently dropped.
  describe "body given for a method that doesn't support one" do
    test "returns {:error, {:unsupported_body, method}} instead of silently dropping it" do
      assert {:error, {:unsupported_body, :get}} =
               HTTP.Httpc.request(:get, "http://127.0.0.1:1/", [], "some body", [])
    end

    test "surfaces through Dowser.Client.request/4 as a Dowser.Client.HTTP.Error" do
      config = Dowser.Client.Config.new(endpoint: "http://127.0.0.1:1", http_adapter: HTTP.Httpc)

      assert {:error, %HTTP.Error{reason: {:unsupported_body, :get}}} =
               Dowser.Client.request(:get, "/", %{"q" => 1}, config: config)
    end

    test "a nil body is unaffected — a GET with no body still succeeds" do
      {port, server} = TCPTestServer.start(@response)
      url = "http://127.0.0.1:#{port}/"

      assert {:ok, %Response{status: 200}} = HTTP.Httpc.request(:get, url, [], nil, [])
      assert Task.await(server).method == "GET"
    end
  end
end
