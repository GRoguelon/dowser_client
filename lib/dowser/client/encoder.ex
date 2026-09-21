defmodule Dowser.Client.Encoder do
  @moduledoc """
  The optional pass over a **document source** in a request body, before it is
  JSON-encoded.

  Only a document source is encoded, never a query. A source's fields are
  described by the mapping of the index it is going to, so it can be encoded
  exactly: this field is a `date` with this format, that one is a `geo_point`. A
  query body has no such anchor — the same value can appear in a range clause, a
  script parameter, an aggregation boundary or a suggester, each wanting a
  different shape — so `dowser_client` never touches one. Build queries in the
  shape the backend expects.

  Encoding is therefore **off unless a request asks for it**, with `:encode`:
  the call site is the only place that knows whether the body it just built
  contains a source, and where.

  ## Options

  `:encoder` can be set per request, on a `Dowser.Client.Context`, or globally
  (`config :dowser_client, encoder: ...`) — most specific wins, as a whole.
  `:encode` is per request only.

    * `:encoder` — the encoder, with the options it needs:

          MyEncoder                          # module exporting encode/2
          {MyEncoder, index: "articles"}     # ... with its options
          fun                                # (source, opts -> term)
          {fun, index: "articles"}           # ... with its options

      The options are whatever the encoder needs — the target index, a mapping, a
      cache reference — and `dowser_client` never looks inside them. `:context`
      (the resolved `Dowser.Client.Context`) is always added to them.

      A request that sets `:encoder` replaces the context's outright, options
      included; there is no per-key merging, so a call that needs its own options
      names the encoder alongside them. A backend package usually writes that
      once, in the function that builds the request.

    * `:encode` — where the source is in this request's body:
      * `false` (default) — nowhere; the body is encoded as given.
      * `true` — the body *is* the source (`PUT /index/_doc/1`).
      * a path — the source sits under it (`["doc"]` for an update). A path is a
        list of `Access` keys, so `["items", Access.at(0)]` reaches through a
        list-valued field. For an ndjson body it applies within each entry — see
        below.
      * a list of paths — several sources in one body (`[["doc"], ["upsert"]]`).

  A path that isn't present in the body — or present but `nil` — is skipped, not
  created, so the encoder is never called with `nil`. The pass is skipped
  altogether for a `nil` body or a `:raw` request format, and when no `:encoder`
  is configured. An encoder is free to raise: it comes back as
  `{:error, %Dowser.Client.Error{reason: {:encode_failed, exception}}}` rather
  than crashing the caller.

  Note that `Date`, `Time`, `NaiveDateTime` and `DateTime` already encode
  themselves as ISO 8601 through Elixir's `JSON` — an encoder is only needed for
  shapes JSON has no opinion about (`Date.Range`, `Decimal`) or a format the
  mapping dictates.

  ## Examples

      # the body is the source
      Dowser.Client.put("/articles/_doc/1", document,
        encoder: {Dowser.Elasticsearch.Encoder, index: "articles"},
        encode: true
      )

      # a partial update: the source is under "doc"
      Dowser.Client.post("/articles/_update/1", %{"doc" => partial},
        encoder: {Dowser.Elasticsearch.Encoder, index: "articles"},
        encode: ["doc"]
      )

      # an upsert carries two of them
      Dowser.Client.post("/articles/_update/1", %{"doc" => partial, "upsert" => full},
        encoder: {Dowser.Elasticsearch.Encoder, index: "articles"},
        encode: [["doc"], ["upsert"]]
      )

      # a search: nothing to encode, so :encode is simply not passed
      Dowser.Client.post("/articles/_search", query)

  An encoder whose options never vary — one that resolves the index from the
  document, say — belongs on the context instead, leaving call sites to pass only
  `:encode`:

      config :dowser_client,
        contexts: [default: [endpoint: "...", encoder: Dowser.Elasticsearch.Encoder]]

  ## An `:ndjson` body

  A line is the unit of an ndjson payload, so the encoder is applied **per
  entry** rather than once over the list — which is what lets a bulk encoder tell
  an action line from a document:

      def encode(%{"index" => _action} = line, _opts), do: line
      def encode(document, opts), do: cast(document, opts[:index])

  `:encode` paths apply within each entry too, so `encode: ["doc"]` over a bulk
  update payload encodes the `"doc"` of every line that has one and skips the
  action lines that don't. See `Dowser.Client.NDJSON`.

  The encoder itself is a black box `dowser_client` knows nothing about: how a
  field's mapping describes it, and what shape the backend wants on the wire, is
  the backend package's knowledge.
  """

  ## Typespecs

  @type encode_fun :: (term(), keyword() -> term())
  @type encoder :: encode_fun() | module() | {encode_fun() | module(), keyword()}
  @type resolved :: {encode_fun(), keyword()}
  @type path :: [term()]
  @type encode :: boolean() | path() | [path()]

  ## Public functions

  @doc """
  Normalizes `:encoder` into `{function, opts}`.

  A module is accepted in place of a function, as long as it exports `encode/2`,
  and either may be paired with the options it needs.
  """
  @spec encoder(encoder() | nil) ::
          {:ok, resolved() | nil} | {:error, {:invalid_encoder, term()}}
  def encoder(encoder)

  def encoder(nil), do: {:ok, nil}

  def encoder({encoder, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, {fun, []}} <- encoder(encoder), do: {:ok, {fun, opts}}
    else
      {:error, {:invalid_encoder, {encoder, opts}}}
    end
  end

  def encoder(fun) when is_function(fun, 2), do: {:ok, {fun, []}}

  def encoder(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :encode, 2) do
      {:ok, {&module.encode/2, []}}
    else
      {:error, {:invalid_encoder, module}}
    end
  end

  def encoder(other), do: {:error, {:invalid_encoder, other}}

  @doc """
  Normalizes `:encode` into `:skip`, `:root`, or the list of paths to encode at.
  """
  @spec encode(encode() | nil) ::
          {:ok, :skip | :root | {:paths, [path()]}} | {:error, {:invalid_encode, term()}}
  def encode(encode)

  def encode(value) when value in [nil, false], do: {:ok, :skip}
  def encode(true), do: {:ok, :root}
  def encode([]), do: {:ok, :root}

  def encode(paths) when is_list(paths) do
    if Enum.all?(paths, &(is_list(&1) and &1 != [])) do
      {:ok, {:paths, paths}}
    else
      {:ok, {:paths, [paths]}}
    end
  end

  def encode(other), do: {:error, {:invalid_encode, other}}

  @doc """
  Runs `encoder` over the source(s) `encode` points at, returning the body
  unchanged when there is nothing to encode.
  """
  @spec run(term(), resolved() | nil, :skip | :root | {:paths, [path()]}) :: term()
  def run(body, encoder, encode)

  # There is nothing to encode in an absent body, so the step is skipped rather
  # than handed to the encoder.
  def run(nil, _encoder, _encode), do: nil

  def run(body, nil, _encode), do: body
  def run(body, _encoder, :skip), do: body
  def run(body, {fun, opts}, :root), do: fun.(body, opts)

  def run(body, {fun, opts}, {:paths, paths}) do
    Enum.reduce(paths, body, &encode_at(&2, &1, fun, opts))
  end

  ## Private functions

  # A path pointing at nothing is left alone rather than created: `update_in/3`
  # would happily insert the key.
  defp encode_at(body, path, fun, opts) do
    case get_in(body, path) do
      nil -> body
      source -> put_in(body, path, fun.(source, opts))
    end
  end
end
