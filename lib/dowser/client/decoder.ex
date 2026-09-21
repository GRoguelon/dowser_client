defmodule Dowser.Client.Decoder do
  @moduledoc """
  The optional second pass over a decoded response body.

  `Dowser.Client.JSON` decodes a body to plain, string-keyed terms and stops
  there. Casting a value beyond JSON (`"2026-09-18"` into `~D[2026-09-18]`)
  needs the mapping of the index that value came from, and a single response can
  carry documents from several indices — so it needs to know where documents sit
  in the envelope, what names it uses for them, and which index each belongs to.
  All of that is one particular search engine's API, which `dowser_client`
  deliberately knows nothing about.

  So the second pass is a black box the backend package supplies: `:decoder` gets
  the decoded body and returns whatever it likes.

  ## Options

  Each can be set per request, on a `Dowser.Client.Context`, or globally
  (`config :dowser_client, keys: ..., decoder: ...`) — most specific wins.

    * `:keys` — `:strings` (default, no casting), `:atoms`, `:atoms!`, or any
      `(String.t() -> term)` function. `:atoms!` uses
      `String.to_existing_atom/1`, so an unknown key raises instead of growing
      the atom table.
    * `:decoder` — the decoder, with the options it needs:

          MyDecoder                       # module exporting decode/2
          {MyDecoder, mapping: mapping}   # ... with its options
          fun                             # (body, opts -> term)
          {fun, mapping: mapping}         # ... with its options

      It is called with the decoded body and its own options, plus two entries
      always added: `:key_fn` (the function `:keys` resolved to,
      `Function.identity/1` when `:keys` is `:strings`) and `:context` (the
      resolved `Dowser.Client.Context`). The rest is whatever the decoder needs —
      an index name, a mapping, a cache reference — and `dowser_client` never
      looks inside it.

      A request that sets `:decoder` replaces the context's outright, options
      included; there is no per-key merging, so a call that needs its own options
      names the decoder alongside them.

  Without a `:decoder`, `:keys` is applied on its own through
  `Dowser.CoreExt.Keyable`. **With** one, the decoder owns the body — keys
  included — and `dowser_client` does not touch it afterwards; that is why
  `:key_fn` is handed over. With neither, there is no second pass at all and the
  body stays exactly as JSON decoded it.

  A decoder returns the decoded term directly. Raising is fine: it comes back as
  `{:error, %Dowser.Client.Error{reason: {:decode_failed, exception}}}` rather
  than crashing the caller.

  The step is skipped entirely — the decoder is never called — for a body there
  is nothing to cast in: an empty payload, a `:raw` response format, or a JSON
  `null` (which decodes to `nil`). A decoder therefore never has to guard against
  `nil`.

  For an `:ndjson` response, a line is the unit: the decoder is called **per
  entry** with each decoded line, not once with the list. See
  `Dowser.Client.NDJSON`.

  ## Example

  What `dowser_elasticsearch` is expected to supply — its own envelope knowledge,
  its own recursion, none of it in `dowser_client`:

      defmodule Dowser.Elasticsearch.Decoder do
        def decode(body, opts) do
          key_fn = Keyword.fetch!(opts, :key_fn)

          do_decode(body, key_fn)
        end


        # A hit carries the index it came from, so its mapping can be resolved
        # and the document cast field by field.
        defp do_decode(%{"_index" => index, "_source" => _source} = hit, key_fn) do
          Map.new(hit, fn
            {"_source" = key, source} -> {key_fn.(key), decode_source(source, index, key_fn)}
            {key, value} -> {key_fn.(key), do_decode(value, key_fn)}
          end)
        end

        defp do_decode(value, key_fn) when is_non_struct_map(value) do
          Map.new(value, fn {key, value} -> {key_fn.(key), do_decode(value, key_fn)} end)
        end

        defp do_decode(value, key_fn) when is_list(value) do
          Enum.map(value, &do_decode(&1, key_fn))
        end

        defp do_decode(value, _key_fn), do: value
      end

      Dowser.Client.get("/articles/_search",
        keys: :atoms,
        decoder: Dowser.Elasticsearch.Decoder
      )

  Or, when the decoder needs something from the call site:

      Dowser.Client.get("/articles/_search",
        keys: :atoms,
        decoder: {Dowser.Elasticsearch.Decoder, mapping: mapping}
      )
  """

  alias Dowser.CoreExt.Keyable

  ## Typespecs

  @type keys :: :strings | :atoms | :atoms! | (String.t() -> term())
  @type key_fun :: (String.t() -> term())
  @type decode_fun :: (term(), keyword() -> term())
  @type decoder :: decode_fun() | module() | {decode_fun() | module(), keyword()}
  @type resolved :: {decode_fun(), keyword()}

  ## Module attributes

  @keys [:strings, :atoms, :atoms!]

  # How close a typo has to be before it is offered as a suggestion.
  @suggestion_threshold 0.77

  ## Public functions

  @doc """
  Resolves the `:keys` option into a key function, or `nil` when it casts
  nothing (`:strings`).
  """
  @spec key_fun(keys() | nil) :: {:ok, key_fun() | nil} | {:error, {:invalid_keys, term()}}
  def key_fun(keys)

  def key_fun(keys) when keys in [nil, :strings], do: {:ok, nil}
  def key_fun(:atoms), do: {:ok, &String.to_atom/1}
  def key_fun(:atoms!), do: {:ok, &String.to_existing_atom/1}
  def key_fun(fun) when is_function(fun, 1), do: {:ok, fun}
  def key_fun(other), do: {:error, {:invalid_keys, other}}

  @doc """
  Normalizes `:decoder` into `{function, opts}`.

  A module is accepted in place of a function, as long as it exports `decode/2`,
  and either may be paired with the options it needs.
  """
  @spec decoder(decoder() | nil) :: {:ok, resolved() | nil} | {:error, {:invalid_decoder, term()}}
  def decoder(decoder)

  def decoder(nil), do: {:ok, nil}

  def decoder({decoder, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, {fun, []}} <- decoder(decoder), do: {:ok, {fun, opts}}
    else
      {:error, {:invalid_decoder, {decoder, opts}}}
    end
  end

  def decoder(fun) when is_function(fun, 2), do: {:ok, {fun, []}}

  def decoder(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :decode, 2) do
      {:ok, {&module.decode/2, []}}
    else
      {:error, {:invalid_decoder, module}}
    end
  end

  def decoder(other), do: {:error, {:invalid_decoder, other}}

  @doc "Whether a second pass is needed at all."
  @spec needed?(key_fun() | nil, resolved() | nil) :: boolean()
  def needed?(key_fun, decoder), do: not (is_nil(key_fun) and is_nil(decoder))

  @doc """
  Runs the second pass over `body`.

  With a `decoder`, it is called with `body` and its own options plus a `:key_fn`
  entry, and owns the result. Without one, `key_fun` is applied to every key of
  `body`.
  """
  @spec run(term(), key_fun() | nil, resolved() | nil) :: term()
  def run(body, key_fun, decoder)

  # There is nothing to cast in an absent body — a JSON `null`, or no body at
  # all — so the step is skipped rather than handed to the decoder.
  def run(nil, _key_fun, _decoder), do: nil

  def run(body, key_fun, nil) when is_function(key_fun, 1) do
    Keyable.transform_keys(body, key_fun)
  end

  def run(body, _key_fun, nil) do
    body
  end

  def run(body, key_fun, {fun, opts}) do
    fun.(body, Keyword.put(opts, :key_fn, key_fun || (&Function.identity/1)))
  end

  @doc """
  The nearest `:keys` value to a bad one, or `nil` when nothing is close — so a
  typo can be reported as "did you mean".
  """
  @spec suggestion(term()) :: atom() | nil
  def suggestion(value) when is_atom(value) or is_binary(value) do
    given = to_string(value)

    @keys
    |> Enum.map(&{&1, String.jaro_distance(given, to_string(&1))})
    |> Enum.filter(fn {_candidate, score} -> score >= @suggestion_threshold end)
    |> Enum.max_by(fn {_candidate, score} -> score end, fn -> nil end)
    |> case do
      {candidate, _score} -> candidate
      nil -> nil
    end
  end

  def suggestion(_value), do: nil

  @doc "The `:keys` values accepted as atoms."
  @spec keys() :: [atom()]
  def keys, do: @keys
end
