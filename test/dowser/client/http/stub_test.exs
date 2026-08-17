defmodule Dowser.Client.HTTP.StubTest do
  use ExUnit.Case, async: true

  alias Dowser.Client
  alias Dowser.Client.Config
  alias Dowser.Client.HTTP.Stub

  describe "request/5" do
    test "raises a clear Dowser.Client.Error when no stub is configured" do
      assert_raise Dowser.Client.Error, ~r/No stub configured for Dowser.Client.HTTP.Stub/, fn ->
        Stub.request(:get, "http://x:9200/", [], nil, [])
      end
    end

    test "the raised error carries :missing_stub as its :reason" do
      try do
        Stub.request(:get, "http://x:9200/", [], nil, [])
        flunk("expected Stub.request/5 to raise")
      rescue
        error in Dowser.Client.Error -> assert error.reason == :missing_stub
      end
    end

    test "delegates to the registered stub function" do
      Stub.stub(fn :get, "http://x:9200/_search", _headers, _body, _opts ->
        Stub.json(200, %{"ok" => true})
      end)

      assert {:ok, response} = Stub.request(:get, "http://x:9200/_search", [], nil, [])
      assert response.status == 200
    end

    test "passes method, url, headers, body and opts through to the stub" do
      Stub.stub(fn method, url, headers, body, opts ->
        send(self(), {:called, method, url, headers, body, opts})
        Stub.raw(204)
      end)

      Stub.request(:post, "http://x:9200/_doc", [{"accept", "json"}], "payload", http: [x: 1])

      assert_received {:called, :post, "http://x:9200/_doc", [{"accept", "json"}], "payload",
                       http: [x: 1]}
    end

    test "a later stub/1 call replaces the previous stub" do
      Stub.stub(fn _, _, _, _, _ -> Stub.raw(200) end)
      Stub.stub(fn _, _, _, _, _ -> Stub.raw(500) end)

      assert {:ok, %{status: 500}} = Stub.request(:get, "http://x:9200/", [], nil, [])
    end

    test "the stub only applies to the process that registered it" do
      Stub.stub(fn _, _, _, _, _ -> Stub.raw(200) end)

      result =
        Task.async(fn ->
          try do
            Stub.request(:get, "http://x:9200/", [], nil, [])
          rescue
            e -> e
          end
        end)
        |> Task.await()

      assert %Dowser.Client.Error{message: message} = result
      assert message =~ "No stub configured"
    end
  end

  describe "json/3" do
    test "encodes the body and defaults the content-type header" do
      assert {:ok, response} = Stub.json(201, %{"a" => 1})

      assert response.status == 201
      assert response.headers["content-type"] == "application/json"
      assert response.body == ~s({"a":1})
    end

    test "does not override an already-present content-type header" do
      assert {:ok, response} = Stub.json(200, %{}, [{"content-type", "application/vnd.custom"}])

      assert response.headers["content-type"] == "application/vnd.custom"
    end
  end

  describe "raw/3" do
    test "defaults to an empty body and no headers" do
      assert {:ok, response} = Stub.raw(204)

      assert response.status == 204
      assert response.body == ""
      assert response.headers == %{}
    end

    test "passes the body and headers through untouched" do
      assert {:ok, response} = Stub.raw(200, "plain text", [{"content-type", "text/plain"}])

      assert response.body == "plain text"
      assert response.headers["content-type"] == "text/plain"
    end
  end

  describe "end-to-end through Dowser.Client" do
    test "drives the full request/response pipeline" do
      Stub.stub(fn :put, url, headers, body, _opts ->
        assert url == "http://x:9200/my-index/_doc/1"
        assert IO.iodata_to_binary(body) == ~s({"title":"hello"})
        assert {"content-type", "application/json"} in headers

        Stub.json(201, %{"_id" => "1", "result" => "created"})
      end)

      config = Config.new(endpoint: "http://x:9200", http_adapter: Stub)

      assert {:ok, response} =
               Client.put("/my-index/_doc/1", %{title: "hello"}, config: config)

      assert response.status == 201
      assert response.body == %{"_id" => "1", "result" => "created"}
    end
  end
end
