defmodule Dowser.RepoTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.Context
  alias Dowser.Client.HTTP.Stub
  alias Dowser.TestRepo

  setup do
    on_exit(fn ->
      for repo <- [TestRepo, TestRepo.WithInit, TestRepo.Verified] do
        Application.delete_env(:dowser_client, repo)
      end
    end)
  end

  defp configure(repo, config), do: Application.put_env(:dowser_client, repo, config)

  describe "not started" do
    test "resolves its configuration on every call, under its own profile" do
      configure(TestRepo, endpoint: "http://repo:9200")

      assert %Context{endpoint: "http://repo:9200", profile: TestRepo} = TestRepo.context()

      configure(TestRepo, endpoint: "http://moved:9200")

      assert %Context{endpoint: "http://moved:9200"} = TestRepo.context()
    end

    test "calls init(:runtime, config)" do
      configure(TestRepo.WithInit, endpoint: "http://repo:9200", test_pid: self())

      assert %Context{auth: {:bearer, "from-init"}} = TestRepo.WithInit.context()
      assert_received {:init, :runtime}
    end

    test "a profile given in the configuration wins over the repo's own" do
      configure(TestRepo, endpoint: "http://repo:9200", profile: :shared)

      assert %Context{profile: :shared} = TestRepo.context()
    end

    test "raises when the configuration has no :endpoint" do
      configure(TestRepo, keys: :atoms)

      assert_raise ArgumentError, ~r/cannot resolve repo Dowser.TestRepo/, fn ->
        TestRepo.context()
      end
    end

    test "has no engine" do
      assert TestRepo.engine() == nil
    end
  end

  describe "started" do
    test "resolves once, init(:supervisor, config) included, then keeps it" do
      configure(TestRepo.WithInit, endpoint: "http://repo:9200", test_pid: self())
      start_supervised!(TestRepo.WithInit)

      assert_received {:init, :supervisor}

      configure(TestRepo.WithInit, endpoint: "http://moved:9200", test_pid: self())

      assert %Context{endpoint: "http://repo:9200", auth: {:bearer, "from-init"}} =
               TestRepo.WithInit.context()

      refute_received {:init, _type}
    end

    test "start_link options are merged over the configuration" do
      configure(TestRepo, endpoint: "http://repo:9200")
      start_supervised!({TestRepo, endpoint: "http://override:9200"})

      assert %Context{endpoint: "http://override:9200"} = TestRepo.context()
    end

    test "stopping it goes back to resolving per call" do
      configure(TestRepo, endpoint: "http://repo:9200")
      start_supervised!({TestRepo, endpoint: "http://override:9200"})
      stop_supervised!(TestRepo)

      assert %Context{endpoint: "http://repo:9200"} = TestRepo.context()
    end

    test "fails to start without an :endpoint" do
      configure(TestRepo, keys: :atoms)

      assert {:error, {:missing_endpoint, _child}} = start_supervised(TestRepo)
    end

    test "verify: true keeps what verify/1 found" do
      configure(TestRepo.Verified,
        endpoint: "http://repo:9200",
        http_opts: [engine: {:opensearch, "2.15.0"}],
        verify: true
      )

      start_supervised!(TestRepo.Verified)

      assert TestRepo.Verified.engine() == {:opensearch, "2.15.0"}
    end

    test "verify: true fails to start when verify/1 says no" do
      configure(TestRepo.Verified, endpoint: "http://repo:9200", verify: true)

      assert {:error, {:not_the_expected_engine, _child}} = start_supervised(TestRepo.Verified)
    end

    test "verify is off by default" do
      configure(TestRepo.Verified, endpoint: "http://repo:9200")
      start_supervised!(TestRepo.Verified)

      assert TestRepo.Verified.engine() == nil
    end
  end

  describe "the HTTP verbs" do
    setup do
      configure(TestRepo, endpoint: "http://repo:9200", auth: {:bearer, "t"})
    end

    test "send to the repo's endpoint, with its auth" do
      Stub.stub(fn :post, url, headers, body, _opts ->
        send(self(), {:request, url, headers, IO.iodata_to_binary(body)})
        Stub.json(200, %{"ok" => true})
      end)

      assert {:ok, %{status: 200, body: %{"ok" => true}}} =
               TestRepo.post("/_plugins/_ml/models/_search", %{query: %{match_all: %{}}})

      assert_received {:request, "http://repo:9200/_plugins/_ml/models/_search", headers, body}
      assert {"authorization", "Bearer t"} in headers
      assert body == ~s({"query":{"match_all":{}}})
    end

    test "every verb goes through request/4" do
      Stub.stub(fn method, _url, _headers, _body, _opts ->
        send(self(), {:method, method})
        Stub.json(200, %{})
      end)

      TestRepo.get("/")
      TestRepo.put("/i/_doc/1", %{})
      TestRepo.patch("/i", %{})
      TestRepo.delete("/i")
      TestRepo.head("/i")

      for method <- [:get, :put, :patch, :delete, :head] do
        assert_received {:method, ^method}
      end
    end
  end

  describe "Dowser.Repo.request/5" do
    test "goes through the repo module's own request/4" do
      configure(TestRepo, endpoint: "http://repo:9200")

      Stub.stub(fn :get, url, _headers, _body, _opts ->
        send(self(), {:url, url})
        Stub.json(200, %{})
      end)

      assert {:ok, _response} = Dowser.Repo.request(TestRepo, :get, "/_cat", nil, repo: TestRepo)
      assert_received {:url, "http://repo:9200/_cat"}
    end

    test "sends an ad-hoc repo straight through Dowser.Client" do
      Stub.stub(fn :get, url, _headers, _body, _opts ->
        send(self(), {:url, url})
        Stub.json(200, %{})
      end)

      assert {:ok, _response} =
               Dowser.Repo.request([endpoint: "http://adhoc:9200"], :get, "/", nil, [])

      assert_received {:url, "http://adhoc:9200/"}
    end
  end

  describe "repo?/1" do
    test "is true for a repo module only" do
      assert Dowser.Repo.repo?(TestRepo)
      refute Dowser.Repo.repo?(String)
      refute Dowser.Repo.repo?(:nope)
      refute Dowser.Repo.repo?(endpoint: "http://x:9200")
      refute Dowser.Repo.repo?(nil)
    end
  end
end
