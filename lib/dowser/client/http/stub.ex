defmodule Dowser.Client.HTTP.Stub do
  @moduledoc """
  Stubs HTTP requests in tests.

  `stub/1` registers a function that answers every request made by the calling
  process, so a test exercises the full `Dowser.Client` pipeline — URL building,
  headers, retries, JSON encoding/decoding — without a search backend running,
  and without `Dowser.Client.HTTP` ever reaching the network.

  The stub is stored in the *calling process*: `stub/1` must run in the same
  process that performs the request (true for a plain ExUnit test body), and
  each process gets its own stub with no shared/global state, so tests can run
  `async: true`. If your code makes requests from another process (e.g. a
  `GenServer`), call `stub/1` from that process instead.

  `body`, as received by the stub function, is the already-encoded request body
  — `iodata`, not necessarily a flat binary; use `IO.iodata_to_binary/1` before
  comparing it to a string. `method` is the method as called, before
  `Dowser.Client.HTTP` would rewrite a `GET` carrying a body into a `POST`.

  ## Examples

      test "indexes a document" do
        Dowser.Client.HTTP.Stub.stub(fn :put, url, _headers, body, _opts ->
          assert url == "http://localhost:9200/my-index/_doc/1"
          assert IO.iodata_to_binary(body) == ~s({"title":"hello"})

          Dowser.Client.HTTP.Stub.json(201, %{"_id" => "1", "result" => "created"})
        end)

        assert {:ok, %{status: 201, body: %{"result" => "created"}}} =
                 Dowser.Client.put("/my-index/_doc/1", %{title: "hello"})
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

  alias Dowser.Client.HTTP
  alias Dowser.Client.JSON
  alias Dowser.Client.Response

  ## Module attributes

  @key {__MODULE__, :stub}

  ## Typespecs

  @type stub_fun ::
          (HTTP.method(), HTTP.url(), HTTP.headers(), HTTP.body(), HTTP.opts() ->
             {:ok, Response.t()} | {:error, term()})

  ## Public functions — configuring stubs

  @doc """
  Registers `fun` as the stub for every request made by the calling process,
  replacing any previously registered stub.

  `fun` receives the same arguments as `Dowser.Client.HTTP.request/5` and must
  return `{:ok, %Dowser.Client.Response{}}` or `{:error, reason}`; `json/3` and
  `raw/3` build a matching response.
  """
  @spec stub(stub_fun()) :: :ok
  def stub(fun) when is_function(fun, 5) do
    Process.put(@key, fun)

    :ok
  end

  @doc "Removes the calling process's stub, so requests hit the network again."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)

    :ok
  end

  @doc """
  Builds a successful JSON response.

  `body` is encoded with `Dowser.Client.JSON`, and a
  `content-type: application/json` header is added unless `headers` already
  has one.
  """
  @spec json(non_neg_integer(), term(), HTTP.headers()) :: {:ok, Response.t()}
  def json(status, body, headers \\ []) do
    {:ok, encoded} = JSON.encode(body)
    headers = put_new_header(headers, "content-type", "application/json")

    raw(status, encoded, headers)
  end

  @doc """
  Builds a response with `body` sent as-is (a binary or iodata).

  Use this for `:raw`-format requests, non-JSON responses, or to hand back
  malformed JSON on purpose to exercise error handling.
  """
  @spec raw(non_neg_integer(), iodata(), HTTP.headers()) :: {:ok, Response.t()}
  def raw(status, body \\ "", headers \\ []) do
    {:ok, Response.new(status, headers, IO.iodata_to_binary(body))}
  end

  ## Public functions — used by the transport

  @doc """
  Returns `{:ok, fun}` when the calling process has a stub registered, `:error`
  otherwise. Called by `Dowser.Client.HTTP.request/5` before every request.
  """
  @spec fetch() :: {:ok, stub_fun()} | :error
  def fetch do
    case Process.get(@key) do
      nil -> :error
      fun -> {:ok, fun}
    end
  end

  ## Private functions

  defp put_new_header(headers, name, value) do
    if Enum.any?(headers, fn {key, _value} -> String.downcase(key) == name end) do
      headers
    else
      [{name, value} | headers]
    end
  end
end
