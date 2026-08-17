defmodule Dowser.Client.HTTP.Stub do
  @moduledoc """
  HTTP adapter for stubbing requests in tests.

  Point a `Dowser.Client.Config` at this adapter
  (`http_adapter: Dowser.Client.HTTP.Stub`) and script its responses with
  `stub/1`, so a test exercises the full
  `Dowser.Client` request/response pipeline — URL building, headers, retries,
  JSON encoding/decoding — without a real search backend running.

  The stub is stored in the *calling process*: `stub/1` must run in the same
  process that performs the request (true for a plain ExUnit test body), and
  each process gets its own stub with no shared/global state, so tests can
  run `async: true`. If your code makes requests from another process (e.g. a
  `GenServer`), call `stub/1` from that process instead.

  `body`, as received by the stub function, is the already-encoded request
  body — `iodata`, not necessarily a flat binary — same as any
  `Dowser.Client.HTTP.Adapter` receives it; use `IO.iodata_to_binary/1` before
  comparing it to a string.

  ## Examples

      test "indexes a document" do
        Dowser.Client.HTTP.Stub.stub(fn :put, url, _headers, body, _opts ->
          assert url == "http://localhost:9200/my-index/_doc/1"
          assert IO.iodata_to_binary(body) == ~s({"title":"hello"})

          Dowser.Client.HTTP.Stub.json(201, %{"_id" => "1", "result" => "created"})
        end)

        config = Dowser.Client.Config.new(endpoint: "http://localhost:9200", http_adapter: __MODULE__)

        assert {:ok, %{status: 201, body: %{"result" => "created"}}} =
                 Dowser.Client.put("/my-index/_doc/1", %{title: "hello"}, config: config)
      end

  A single `stub/1` handles every request made by the process for the rest of
  the test; call it again to change behaviour partway through, or have the
  function branch on `method`/`url` to script multiple endpoints:

      Dowser.Client.HTTP.Stub.stub(fn
        :get, "http://localhost:9200/my-index/_search", _headers, _body, _opts ->
          Dowser.Client.HTTP.Stub.json(200, %{"hits" => %{"hits" => []}})

        :post, "http://localhost:9200/_bulk", _headers, _body, _opts ->
          Dowser.Client.HTTP.Stub.json(200, %{"errors" => false})
      end)
  """

  @behaviour Dowser.Client.HTTP.Adapter

  alias Dowser.Client.HTTP.Adapter
  alias Dowser.Client.JSON.Native
  alias Dowser.Client.Response

  @key {__MODULE__, :stub}

  ## Typespecs

  @type stub_fun ::
          (Adapter.method(), Adapter.url(), Adapter.headers(), Adapter.body(), Adapter.opts() ->
             {:ok, Response.t()} | {:error, term()})

  ## Public functions — configuring stubs

  @doc """
  Registers `fun` as the stub for every request made by the calling process,
  replacing any previously registered stub.

  `fun` receives the same arguments as `c:Dowser.Client.HTTP.Adapter.request/5`
  and must return `{:ok, %Dowser.Client.Response{}}` or `{:error, reason}`;
  `json/3` and `raw/3` build a matching response.
  """
  @spec stub(stub_fun()) :: :ok
  def stub(fun) when is_function(fun, 5) do
    Process.put(@key, fun)
    :ok
  end

  @doc """
  Builds a successful JSON response.

  `body` is encoded with `Dowser.Client.JSON.Native` — independent of
  whichever JSON adapter the config under test is configured with — and a
  `content-type: application/json` header is added unless `headers` already
  has one.
  """
  @spec json(non_neg_integer(), term(), Adapter.headers()) :: {:ok, Response.t()}
  def json(status, body, headers \\ []) do
    {:ok, encoded} = Native.encode(body, [])
    headers = put_new_header(headers, "content-type", "application/json")
    raw(status, encoded, headers)
  end

  @doc """
  Builds a response with `body` sent as-is (a binary or iodata).

  Use this for `:raw`-format requests, non-JSON responses, or to hand back
  malformed JSON on purpose to exercise error handling.
  """
  @spec raw(non_neg_integer(), iodata(), Adapter.headers()) :: {:ok, Response.t()}
  def raw(status, body \\ "", headers \\ []) do
    {:ok, Response.new(status, headers, IO.iodata_to_binary(body))}
  end

  ## Behaviour callback

  @impl Dowser.Client.HTTP.Adapter
  def request(method, url, headers, body, opts) do
    case Process.get(@key) do
      nil -> missing_stub!()
      fun -> fun.(method, url, headers, body, opts)
    end
  end

  ## Private functions

  defp put_new_header(headers, name, value) do
    if Enum.any?(headers, fn {k, _v} -> String.downcase(k) == name end) do
      headers
    else
      [{name, value} | headers]
    end
  end

  defp missing_stub! do
    raise Dowser.Client.Error,
      reason: :missing_stub,
      message: """
      No stub configured for #{inspect(__MODULE__)} in this process (#{inspect(self())}).

      Call #{inspect(__MODULE__)}.stub/1 before making a request, e.g. in your \
      test's `setup` block. The stub only applies to the process that \
      registered it — if the request happens in another process, call \
      stub/1 from there instead.
      """
  end
end
