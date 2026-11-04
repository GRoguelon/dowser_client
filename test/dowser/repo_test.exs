defmodule Dowser.RepoTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP.Stub
  alias Dowser.Repo.Config
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

      assert %Config{endpoint: "http://repo:9200", profile: TestRepo} = TestRepo.config()

      configure(TestRepo, endpoint: "http://moved:9200")

      assert %Config{endpoint: "http://moved:9200"} = TestRepo.config()
    end

    test "calls init(:runtime, config)" do
      configure(TestRepo.WithInit, endpoint: "http://repo:9200", test_pid: self())

      assert %Config{auth: {:bearer, "from-init"}} = TestRepo.WithInit.config()
      assert_received {:init, :runtime, TestRepo.WithInit}
    end

    test "a profile given in the configuration wins over the repo's own" do
      configure(TestRepo, endpoint: "http://repo:9200", profile: :shared)

      assert %Config{profile: :shared} = TestRepo.config()
    end

    test "raises when the configuration has no :endpoint" do
      configure(TestRepo, keys: :atoms)

      assert_raise ArgumentError, ~r/cannot resolve repo Dowser.TestRepo/, fn ->
        TestRepo.config()
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

      assert_received {:init, :supervisor, TestRepo.WithInit}

      configure(TestRepo.WithInit, endpoint: "http://moved:9200", test_pid: self())

      assert %Config{endpoint: "http://repo:9200", auth: {:bearer, "from-init"}} =
               TestRepo.WithInit.config()

      refute_received {:init, _type, _name}
    end

    test "start_link options are merged over the configuration" do
      configure(TestRepo, endpoint: "http://repo:9200")
      start_supervised!({TestRepo, endpoint: "http://override:9200"})

      assert %Config{endpoint: "http://override:9200"} = TestRepo.config()
    end

    test "stopping it goes back to resolving per call" do
      configure(TestRepo, endpoint: "http://repo:9200")
      start_supervised!({TestRepo, endpoint: "http://override:9200"})
      stop_supervised!(TestRepo)

      assert %Config{endpoint: "http://repo:9200"} = TestRepo.config()
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

  describe "dynamic instances" do
    setup do
      configure(TestRepo, endpoint: "http://static:9200", keys: :atoms)

      start_supervised!(TestRepo)
      start_supervised!({TestRepo, name: :tenant_a, endpoint: "http://a:9200"})
      start_supervised!({TestRepo, name: :tenant_b, endpoint: "http://b:9200"})

      :ok
    end

    test "each has its own configuration over the static one, and its own pool" do
      assert %Config{endpoint: "http://static:9200", profile: TestRepo} = TestRepo.config()

      assert %Config{endpoint: "http://a:9200", keys: :atoms, profile: :tenant_a} =
               Dowser.Repo.config({TestRepo, :tenant_a})

      assert %Config{endpoint: "http://b:9200", profile: :tenant_b} =
               Dowser.Repo.config({TestRepo, :tenant_b})
    end

    test "put_dynamic_repo/1 switches the calling process, and returns the previous one" do
      assert TestRepo.get_dynamic_repo() == TestRepo
      assert TestRepo.put_dynamic_repo(:tenant_a) == TestRepo
      assert %Config{endpoint: "http://a:9200"} = TestRepo.config()

      assert TestRepo.put_dynamic_repo(TestRepo) == :tenant_a
      assert %Config{endpoint: "http://static:9200"} = TestRepo.config()
    end

    test "the choice is the calling process's own" do
      TestRepo.put_dynamic_repo(:tenant_a)

      assert %Config{endpoint: "http://static:9200"} =
               Task.async(fn -> TestRepo.config() end) |> Task.await()
    end

    test "with_dynamic_repo/2 switches for the duration of the function, even when it raises" do
      assert %Config{endpoint: "http://b:9200"} =
               TestRepo.with_dynamic_repo(:tenant_b, fn -> TestRepo.config() end)

      assert TestRepo.get_dynamic_repo() == TestRepo

      assert_raise RuntimeError, fn ->
        TestRepo.with_dynamic_repo(:tenant_b, fn -> raise "boom" end)
      end

      assert TestRepo.get_dynamic_repo() == TestRepo
    end

    test "init/2 receives the instance's name" do
      configure(TestRepo.WithInit, endpoint: "http://repo:9200", test_pid: self())
      start_supervised!({TestRepo.WithInit, name: :tenant_init})

      assert_received {:init, :supervisor, :tenant_init}
    end

    test "{repo, name} targets an instance without touching the process's choice" do
      Stub.stub(fn :get, url, _headers, _body, _opts ->
        send(self(), {:url, url})
        Stub.json(200, %{})
      end)

      assert {:ok, _response} = Dowser.Client.get("/", repo: {TestRepo, :tenant_a})
      assert_received {:url, "http://a:9200/"}

      assert {:ok, _response} = Dowser.Repo.request({TestRepo, :tenant_b}, :get, "/", nil, [])
      assert_received {:url, "http://b:9200/"}

      assert TestRepo.get_dynamic_repo() == TestRepo
    end

    test "the HTTP verbs follow the process's dynamic repo" do
      Stub.stub(fn :get, url, _headers, _body, _opts ->
        send(self(), {:url, url})
        Stub.json(200, %{})
      end)

      TestRepo.put_dynamic_repo(:tenant_b)
      TestRepo.get("/_cat/indices")

      assert_received {:url, "http://b:9200/_cat/indices"}
    end

    test "an instance that isn't started can't be used" do
      assert_raise ArgumentError, ~r/no instance :nope of repo Dowser.TestRepo is started/, fn ->
        Dowser.Repo.config({TestRepo, :nope})
      end

      assert {:error, {:invalid_repo, {TestRepo, :nope}, _message}} =
               Config.resolve({TestRepo, :nope})

      stop_supervised!(:tenant_a)

      assert {:error, {:invalid_repo, {TestRepo, :tenant_a}, _message}} =
               Config.resolve({TestRepo, :tenant_a})
    end

    test "another repo module can't answer for an instance it didn't start" do
      configure(TestRepo.Verified, endpoint: "http://verified:9200")

      assert_raise ArgumentError, fn -> Dowser.Repo.config({TestRepo.Verified, :tenant_a}) end
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

  describe "a mock repo" do
    test "a module implementing request/4 answers in place of a repo" do
      assert {:ok, %{body: %{"mocked" => [:get, "/_cat"]}}} =
               Dowser.Repo.request(Dowser.TestMockRepo, :get, "/_cat", nil, [])
    end

    test "it isn't a repo: there is no configuration to resolve" do
      refute Dowser.Repo.repo?(Dowser.TestMockRepo)
      assert {:error, {:unknown_repo, Dowser.TestMockRepo}} = Config.resolve(Dowser.TestMockRepo)
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
