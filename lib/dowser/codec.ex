defmodule Dowser.Codec do
  @moduledoc """
  The engine behind each backend package's codec — the module a repo names as
  its `Dowser.Client` `:decoder` and `:encoder`:

      config :my_app, MyApp.Search,
        endpoint: "http://localhost:9200",
        decoder: Dowser.OpenSearch.Codec,
        encoder: Dowser.OpenSearch.Codec

  A backend codec is three one-line functions handing their arguments here
  with its own `t:config/0`: which mapping cacher it reads, which application
  environment and telemetry prefix are its own, and which mapping types are
  opaque on that backend (`flat_object` on OpenSearch, `flattened` on
  Elasticsearch).

  Casting itself is split three ways, each in its own module:

    * `Dowser.Envelope` finds the documents in a response body;
    * `Dowser.Source` walks one document against its mapping — objects,
      nested fields, arrays, structs;
    * `Dowser.Type` casts one leaf value — a date, a range, an IP address.

  This module decides which mapping they work against, and what happens when
  it can't be had.

  ## decode/3

  Casts every document found in a response body (see `Dowser.Envelope`), each
  against its own index's mapping. With `source: true` the body is a bare
  `_source` document with no `_index` of its own, cast against `opts[:index]`'s
  mapping.

  ## encode/3

  Casts one **document source** against the mapping of `opts[:index]` — never a
  query. `dowser_client` only hands an encoder a source, because a query value
  has no mapping entry to anchor it: the same value can appear in a range
  clause, a script parameter or an aggregation boundary, each wanting a
  different shape. Build queries in the shape the backend expects.

  `encode_bulk/3` is the exception to one-source-at-a-time: a bulk payload is
  cast against the index named on the action line above it, which no per-line
  pass can see.

  ## Options

  `dowser_client` always supplies `:repo_config` (the request's repo, resolved
  into a `Dowser.Repo.Config`), and a decoder also gets `:key_fn` (the function
  `:keys` resolved to). The API function sets `:index` (the index a source is
  cast against) and `:source` (`true` when a response body is a bare `_source`
  document). The rest decide how documents are cast:

    * `:mapping` — where the mapping comes from: a map (the mapping itself), a
      module implementing `Dowser.Mapping`, or a document module (its own
      mapping). Defaults to the backend's mapping cacher — the cluster's
      mapping, which the application has to start. Documents come back as
      maps.
    * `:struct` — a document module (`Dowser.Schema`): every document is loaded
      into its struct, and its struct dumped back, against its own mapping.
      Passing a different `:mapping` alongside it is an `ArgumentError`.
    * `:types` — the `Dowser.Type` module leaf values are cast through
      (default `Dowser.Type`).
    * `:unknown_fields` — a field the mapping doesn't declare is `:keep`-t as
      it is (default), or `:raise`s a `Dowser.UnknownFieldError`. Maps only: a
      struct has no room for an undeclared field, so loading one always raises.
    * `:mapping_failure` — what to do when the mapping *cannot be fetched*;
      see below. Default `:error`.

  Each is resolved per request, then from the options the repo gives the
  codec (`decoder: {Dowser.OpenSearch.Codec, types: MyApp.Types}`), then from
  the backend's application environment
  (`config :dowser_opensearch, types: MyApp.Types`) — except `:struct`, which
  only makes sense per request. So the application-wide mapping source is

      config :dowser_opensearch, mapping: MyApp.Mappings

  with the backend's cacher the default when nothing is set. `:struct` always
  casts against its own mapping, whatever the application sets.

  ## When the mapping can't be fetched

  An index with no mapping, and no index to speak of, both cast to identity:
  there is nothing to dispatch on, and that is a correct answer.

  A mapping that could not be *fetched* is a different thing. The fetch is a
  request like any other, so it fails when the cluster is overloaded — and
  casting to identity there means the same field comes back as a `Date.Range`
  on a good day and a `%{"gte" => _, "lte" => _}` on a bad one, a document
  source is written with a `Date.Range` the JSON encoder chokes on, and nothing
  says so. `:mapping_failure` decides what happens instead:

    * `:error` (default) — raise `Dowser.MappingError`, which `dowser_client`
      turns into the `{:error, exception}` every API function already returns.
      The request fails; the types don't drift.
    * `:warn` — log a warning and cast to identity.
    * `:ignore` — cast to identity, silently.

  A `Dowser.MappingCacher` only gets there for a mapping it has nothing to
  fall back on: one it has never fetched, or one past its `:max_stale`. An
  expired mapping is served stale while it is refreshed, and a refresh that
  fails doesn't fail the request.

  Where `:telemetry` is available — an optional dependency, so only if your
  application already pulls it in — every failed fetch also emits
  `[otp_app, :mapping, :failure]` (`[:dowser_opensearch, :mapping, :failure]`
  for OpenSearch) whatever the policy, with
  `%{index: index, reason: reason, policy: policy}` as metadata.
  """

  require Logger

  alias Dowser.MappingError

  ## Module attributes

  @actions [:index, :create, :update, :delete]

  # Where an update action's source sits, in both key styles — a key that isn't
  # there is skipped rather than created.
  @update_keys [:doc, :upsert]

  ## Typespecs

  @typedoc """
  A backend codec's own settings:

    * `:otp_app` — the backend's application: where `:types`,
      `:unknown_fields` and `:mapping_failure` are read from, and the telemetry
      event prefix.
    * `:cacher` — its `Dowser.MappingCacher` module, the default `:mapping`.
    * `:opaque` — the mapping types whose subtree is never cast.
  """
  @type config :: %{otp_app: atom(), cacher: module(), opaque: [String.t()]}

  ## Public functions

  @doc """
  Casts every document found in `body`, returning the decoded term.

  See the module documentation for the options; `:key_fn` is required, and
  `dowser_client` always supplies it.
  """
  @spec decode(term(), keyword(), config()) :: term()
  def decode(body, opts, config) do
    casting = casting(opts, config)
    source_opts = source_opts(casting, config, key_fn: Keyword.fetch!(opts, :key_fn))

    if Keyword.get(opts, :source, false) do
      load_source(body, Keyword.get(opts, :index), casting, opts, config, source_opts)
    else
      Dowser.Envelope.load(body, &mapping(&1, casting, opts, config), source_opts)
    end
  end

  @doc """
  Casts `source` against the mapping of `opts[:index]` — or, with `:struct`,
  against the struct's — returning the encoded term.

  Without an `:index` or a `:mapping` there is no mapping to cast against, and
  the source passes through unchanged. See the module documentation for the
  options.
  """
  @spec encode(term(), keyword(), config()) :: term()
  def encode(source, opts, config) do
    casting = casting(opts, config)
    source_opts = source_opts(casting, config, [])

    case {casting.struct, source} do
      {struct, %struct{}} ->
        struct.__dump__(source, source_opts)

      _other ->
        mapping = mapping(Keyword.get(opts, :index), casting, opts, config)

        Dowser.Source.dump(source, mapping, source_opts)
    end
  end

  @doc """
  Casts the payloads of a bulk operation list.

  A bulk body is a flat list alternating action and payload maps, so a payload
  only knows which index it is going to from the action line above it — which
  is why it is cast here, over the whole list, rather than line by line through
  `Dowser.Client`'s `:encode`.

  `fun` is the resolved encoder (a codec's `encode/2` or a custom one) and
  `opts` its options; `opts[:index]` is the bulk-level default index, which a
  per-action `_index` overrides. `index`/`create` actions have their whole
  payload cast, `update` actions only their `doc`/`upsert` source, and
  `delete` actions carry no payload to cast.
  """
  @spec encode_bulk([map()], (term(), keyword() -> term()), keyword()) :: [map()]
  def encode_bulk(operations, fun, opts) when is_list(operations) do
    default_index = Keyword.get(opts, :index)

    {items, _state} =
      Enum.map_reduce(operations, :header, &bulk_step(&1, &2, fun, opts, default_index))

    items
  end

  ## Private functions — the options

  @removed %{
    codec:
      "the :codec option is now :types — it names the Dowser.Type module leaves are cast through"
  }

  defp casting(opts, config) do
    reject_removed!(opts, config)

    struct = document_module!(Keyword.get(opts, :struct))
    mapping = Keyword.get(opts, :mapping)

    if struct && mapping && mapping != struct do
      raise ArgumentError,
            "struct: #{inspect(struct)} casts against its own mapping, so it can't be " <>
              "combined with mapping: #{inspect(mapping)}"
    end

    %{
      struct: struct,
      mapping: struct || mapping || Application.get_env(config.otp_app, :mapping),
      types: option(opts, config, :types, Dowser.Type),
      unknown_fields: option(opts, config, :unknown_fields, :keep)
    }
  end

  defp option(opts, config, key, default) do
    Keyword.get(opts, key) || Application.get_env(config.otp_app, key, default)
  end

  defp document_module!(nil), do: nil

  defp document_module!(struct) do
    if Dowser.Schema.schema?(struct) do
      struct
    else
      raise ArgumentError,
            "struct: #{inspect(struct)} is not a document module — it needs " <>
              "__schema__/1, __load__/2 and __dump__/2 (see Dowser.Schema)"
    end
  end

  # `:codec` named the type module until 0.4; left in place it would be ignored
  # without a word, and every value come back uncast.
  defp reject_removed!(opts, config) do
    Enum.each(@removed, fn {key, hint} ->
      if Keyword.has_key?(opts, key) or Application.get_env(config.otp_app, key) != nil do
        raise ArgumentError, hint
      end
    end)
  end

  defp source_opts(casting, config, extra) do
    Keyword.merge(
      [
        types: casting.types,
        opaque: config.opaque,
        unknown_fields: casting.unknown_fields,
        struct: casting.struct
      ],
      extra
    )
  end

  # A bare `_source` (a get-source response) has no hit around it: its index
  # is the request's, and that is all the metadata there is.
  defp load_source(body, index, casting, opts, config, source_opts) do
    case casting.struct do
      nil ->
        Dowser.Source.load(body, mapping(index, casting, opts, config), source_opts)

      struct ->
        struct.__load__(body, Dowser.Envelope.struct_opts(source_opts, %{"_index" => index}))
    end
  end

  ## Private functions — the mapping

  defp mapping(index, casting, opts, config) do
    case casting.mapping do
      nil ->
        fetch(config.cacher, index, opts, config)

      %{} = mapping ->
        mapping

      module when is_atom(module) ->
        if function_exported?(module, :fetch_mapping, 2) or not Dowser.Schema.schema?(module) do
          fetch(module, index, opts, config)
        else
          module.__schema__(:mapping)
        end
    end
  end

  defp fetch(source, index, opts, config) do
    case source.fetch_mapping(index, Keyword.get(opts, :repo_config)) do
      {:ok, mapping} ->
        mapping

      {:error, reason} ->
        failed(index, reason, opts, config)
    end
  end

  defp failed(index, reason, opts, config) do
    policy = mapping_failure(opts, config)

    emit_failure(config.otp_app, %{index: index, reason: reason, policy: policy})

    case policy do
      :error ->
        raise MappingError, index: index, reason: reason

      :warn ->
        Logger.warning(Exception.message(%MappingError{index: index, reason: reason}))

        nil

      :ignore ->
        nil
    end
  end

  # `:telemetry` is an optional dependency: the event is emitted for the
  # applications that have it, and costs nothing for the ones that don't.
  if Code.ensure_loaded?(:telemetry) do
    defp emit_failure(otp_app, metadata) do
      :telemetry.execute([otp_app, :mapping, :failure], %{count: 1}, metadata)
    end
  else
    defp emit_failure(_otp_app, _metadata), do: :ok
  end

  defp mapping_failure(opts, config) do
    Keyword.get(opts, :mapping_failure) ||
      Application.get_env(config.otp_app, :mapping_failure, :error)
  end

  ## Private functions — bulk

  defp bulk_step(item, :header, _fun, _opts, default_index) do
    {action, header} = bulk_action(item)
    index = fetch_any(header, :_index) || default_index
    next = if action == :delete, do: :header, else: {:payload, action, index}

    {item, next}
  end

  defp bulk_step(item, {:payload, :update, index}, fun, opts, _default_index) do
    opts = Keyword.put(opts, :index, index)

    {Enum.reduce(@update_keys, item, &encode_key(&2, &1, fun, opts)), :header}
  end

  defp bulk_step(item, {:payload, _action, index}, fun, opts, _default_index) do
    {fun.(item, Keyword.put(opts, :index, index)), :header}
  end

  # An action line is `%{action => header}`, keyed by atom or string; one that
  # names no known action is read as an `index`, as the backend reads it too.
  defp bulk_action(header) do
    Enum.find_value(@actions, {:index, header}, fn action ->
      case fetch_any(header, action) do
        %{} = value ->
          {action, value}

        _other ->
          nil
      end
    end)
  end

  # A bulk payload may be written with atom or string keys, so both are tried.
  defp encode_key(%{} = term, key, fun, opts) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(term, key) ->
        Map.update!(term, key, &fun.(&1, opts))

      Map.has_key?(term, string_key) ->
        Map.update!(term, string_key, &fun.(&1, opts))

      true ->
        term
    end
  end

  defp fetch_any(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
