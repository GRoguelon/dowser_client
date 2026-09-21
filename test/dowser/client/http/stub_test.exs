defmodule Dowser.Client.HTTP.StubTest do
  use ExUnit.Case, async: true

  alias Dowser.Client
  alias Dowser.Client.HTTP
  alias Dowser.Client.HTTP.Stub

  describe "interception" do
    test "Dowser.Client.HTTP.request/5 goes to the registered stub" do
      Stub.stub(fn :get, "http://x:9200/_search", _headers, _body, _opts ->
        Stub.json(200, %{"ok" => true})
      end)

      assert {:ok, response} = HTTP.request(:get, "http://x:9200/_search", [], nil, [])
      assert response.status == 200
    end

    test "passes method, url, headers, body and opts through to the stub" do
      Stub.stub(fn method, url, headers, body, opts ->
        send(self(), {:called, method, url, headers, body, opts})

        Stub.raw(204)
      end)

      HTTP.request(:post, "http://x:9200/_doc", [{"accept", "json"}], "payload", timeout: 1)

      assert_received {:called, :post, "http://x:9200/_doc", [{"accept", "json"}], "payload",
                       [timeout: 1]}
    end

    test "the stub sees the method as called, before any GET-to-POST rewrite" do
      Stub.stub(fn method, _url, _headers, _body, _opts ->
        send(self(), {:called, method})

        Stub.raw(200)
      end)

      HTTP.request(:get, "http://x:9200/_search", [], "a body", [])

      assert_received {:called, :get}
    end

    test "a later stub/1 call replaces the previous stub" do
      Stub.stub(fn _, _, _, _, _ -> Stub.raw(200) end)
      Stub.stub(fn _, _, _, _, _ -> Stub.raw(500) end)

      assert {:ok, %{status: 500}} = HTTP.request(:get, "http://x:9200/", [], nil, [])
    end

    test "clear/0 removes it" do
      Stub.stub(fn _, _, _, _, _ -> Stub.raw(200) end)
      assert {:ok, _fun} = Stub.fetch()

      assert :ok = Stub.clear()
      assert :error = Stub.fetch()
    end

    # Requests from another process are not stubbed — they hit the network,
    # where this made-up host does not resolve.
    test "the stub only applies to the process that registered it" do
      Stub.stub(fn _, _, _, _, _ -> Stub.raw(200) end)

      task =
        Task.async(fn ->
          assert :error = Stub.fetch()

          HTTP.request(:get, "http://dowser.invalid.test:9200/", [], nil, connect_timeout: 500)
        end)

      assert {:error, _reason} = Task.await(task, 5_000)
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

      assert {:ok, response} =
               Client.put("/my-index/_doc/1", %{title: "hello"},
                 context: [endpoint: "http://x:9200"]
               )

      assert response.status == 201
      assert response.body == %{"_id" => "1", "result" => "created"}
    end
  end
end
