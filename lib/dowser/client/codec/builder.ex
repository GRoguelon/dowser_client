defmodule Dowser.Client.Codec.Builder do
  @moduledoc """
  Builds a `load/2` + `dump/2` dispatcher from a list of `Dowser.Client.Field`
  mappings.

  `use Dowser.Client.Codec.Builder` turns a module into a `Dowser.Client.Field`-
  shaped dispatcher: it exposes a `cast/2` macro to declare, for a pattern
  matched against the second argument (typically field metadata), which
  `Dowser.Client.Field` module handles it. At compile time this expands into
  plain `load/2`/`dump/2` function clauses — one pattern-matched clause per
  `cast/2`, dispatching straight to the field module, with no indirection at
  runtime.

  A module built this way implements `Dowser.Client.Field`'s per-*value*
  contract (`load/2`/`dump/2`), so it is what a backend package's `:decoder`
  dispatches *into*, field by field — it is not itself the `:decoder`, which
  receives a whole response body. See the bridging example at the bottom of this
  moduledoc, and `Dowser.Client.Decoder` for how the second pass is configured.

      defmodule Dowser.Elasticsearch.Fields.Date do
        @behaviour Dowser.Client.Field

        @impl true
        def load(value, %{"format" => "strict_date"}) when is_binary(value) do
          case Date.from_iso8601(value) do
            {:ok, date} -> date
            {:error, _reason} -> value
          end
        end

        def load(value, _field), do: value

        @impl true
        def dump(%Date{} = date, %{"format" => "strict_date"}) do
          Date.to_iso8601(date)
        end

        def dump(value, _field), do: value
      end

      defmodule Dowser.Elasticsearch.FieldCodec do
        use Dowser.Client.Codec.Builder

        cast %{"type" => "date"}, Dowser.Elasticsearch.Fields.Date
      end

  compiles down to (roughly):

      defmodule Dowser.Elasticsearch.FieldCodec do
        def load(nil, _field), do: nil

        def load(value, %{"type" => "date"} = field) do
          Dowser.Elasticsearch.Fields.Date.load(value, field)
        end

        def load(value, _field), do: value

        def dump(nil, _field), do: nil

        def dump(value, %{"type" => "date"} = field) do
          Dowser.Elasticsearch.Fields.Date.dump(value, field)
        end

        def dump(value, _field), do: value
      end

  ## From field codec to a `:decoder`

  `Dowser.Client.Decoder` calls a request's `:decoder` with the whole decoded
  body and an option list carrying `:key_fn`. Everything else — where documents
  sit in the envelope, which index each came from, what that index' mapping is —
  is the backend package's own knowledge, so it walks the body itself and
  dispatches field by field into its `Codec.Builder`-built module:

      defmodule Dowser.Elasticsearch.Fields.DateRange do
        @behaviour Dowser.Client.Field

        alias Dowser.Elasticsearch.Fields.Date, as: DateField

        # A range value is an object of bounds:
        # %{"gte" => "2026-09-01", "lt" => "2026-10-01"}
        @impl true
        def load(value, field) when is_map(value) do
          Map.new(value, fn {bound, bound_value} ->
            {bound, DateField.load(bound_value, field)}
          end)
        end

        def load(value, _field), do: value

        @impl true
        def dump(value, field) when is_map(value) do
          Map.new(value, fn {bound, bound_value} ->
            {bound, DateField.dump(bound_value, field)}
          end)
        end

        def dump(value, _field), do: value
      end

      defmodule Dowser.Elasticsearch.FieldCodec do
        use Dowser.Client.Codec.Builder

        cast %{"type" => "date"}, Dowser.Elasticsearch.Fields.Date
        cast %{"type" => "date_range"}, Dowser.Elasticsearch.Fields.DateRange
      end

      defmodule Dowser.Elasticsearch.Decoder do
        alias Dowser.Elasticsearch.FieldCodec

        def decode(body, opts) do
          do_decode(body, Keyword.fetch!(opts, :key_fn))
        end

        # A hit carries its own index, so the mapping to cast it against can be
        # resolved right here.
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

        defp decode_source(source, index, key_fn) do
          {:ok, %{"properties" => properties}} = MappingCache.fetch(index)

          Enum.reduce(properties, %{}, fn {field, options}, acc ->
            case Map.fetch(source, field) do
              {:ok, value} -> Map.put(acc, key_fn.(field), FieldCodec.load(value, options))
              :error -> acc
            end
          end)
        end
      end

  Used per request:

      Dowser.Client.get("/articles/_search",
        keys: :atoms,
        decoder: &Dowser.Elasticsearch.Decoder.decode/2
      )

      #=> %{hits: %{hits: [
      #=>   %{_index: "articles", _id: "1", _source: %{
      #=>     title: "hello",
      #=>     published_at: ~D[2026-09-18],
      #=>     run_window: %{"gte" => ~D[2026-09-01], "lt" => ~D[2026-10-01]}
      #=>   }}
      #=> ]}}

  `dump/2` goes the other way, on a document the package is about to send — which
  is what an `:encoder` dispatches into, given the mapping of the index being
  written to:

      defmodule Dowser.Elasticsearch.Encoder do
        alias Dowser.Elasticsearch.FieldCodec

        def encode(source, opts) do
          {:ok, %{"properties" => properties}} = MappingCache.fetch(opts[:index])

          Map.new(source, fn {field, value} ->
            {field, FieldCodec.dump(value, properties[field])}
          end)
        end
      end

      # the body is the source
      Dowser.Client.put("/articles/_doc/1", document,
        encoder: {Dowser.Elasticsearch.Encoder, index: "articles"},
        encode: true
      )

      # a partial update: the source sits under "doc"
      Dowser.Client.post("/articles/_update/1", %{"doc" => partial},
        encoder: {Dowser.Elasticsearch.Encoder, index: "articles"},
        encode: ["doc"]
      )

  See `Dowser.Client.Decoder` and `Dowser.Client.Encoder` for both passes' full
  contracts.

  ## Options

    * `:inherit` — a module built with `Dowser.Client.Codec.Builder` whose `cast/2`
      declarations are inserted ahead of this module's own. A pattern
      declared by the inherited module wins over one declared later for an
      overlapping match, since clauses are tried top to bottom. Default
      `nil` (no inheritance).
    * `:fallback` — `true` (default) adds a catch-all `load/2`/`dump/2`
      clause returning the value as-is when nothing else matched. `false`
      omits it, so an unmatched value raises `FunctionClauseError`.
    * `:nil` — `true` (default) adds a `load(nil, _)`/`dump(nil, _)` clause
      returning `nil` ahead of every other clause, so fields never have to
      guard against `nil` themselves. `false` omits it.

  ## Ordering

  Generated clauses are tried in this order: the `nil` guard (if enabled),
  then the inherited module's casts (if any), then this module's own casts
  in declaration order, then the fallback (if enabled). `load/2` clauses are
  emitted before `dump/2` clauses.
  """

  ## Module attributes

  @default_opts [inherit: nil, fallback: true, nil: true]

  ## Macros

  @doc """
  Declares that a value whose field metadata matches `pattern` is handled by
  `field_module` — a module implementing `Dowser.Client.Field`.

  `pattern` is matched against the second argument of `load/2`/`dump/2`
  (conventionally the field's own metadata); the matched value is bound to
  `field` and passed through to `field_module.load/2` or `field_module.dump/2`
  alongside the original value.
  """
  defmacro cast(pattern, field_module) do
    field_module = Macro.expand(field_module, __CALLER__)

    quote do
      Module.put_attribute(
        __MODULE__,
        :dowser_codec_casts,
        {unquote(Macro.escape(pattern)), unquote(field_module)}
      )
    end
  end

  @doc false
  defmacro __using__(opts) do
    opts = validate_opts!(opts)
    inherit = Macro.expand(Keyword.fetch!(opts, :inherit), __CALLER__)

    quote do
      import Dowser.Client.Codec.Builder, only: [cast: 2]

      @behaviour Dowser.Client.Field

      Module.register_attribute(__MODULE__, :dowser_codec_casts, accumulate: true)
      @dowser_codec_inherit unquote(inherit)
      @dowser_codec_fallback? unquote(Keyword.fetch!(opts, :fallback))
      @dowser_codec_nil? unquote(Keyword.fetch!(opts, nil))

      @before_compile Dowser.Client.Codec.Builder
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    own_casts = env.module |> Module.get_attribute(:dowser_codec_casts) |> Enum.reverse()
    inherit = Module.get_attribute(env.module, :dowser_codec_inherit)
    fallback? = Module.get_attribute(env.module, :dowser_codec_fallback?)
    nil? = Module.get_attribute(env.module, :dowser_codec_nil?)

    casts = inherited_casts(inherit) ++ own_casts

    quote do
      @doc false
      @spec __casts__() :: [{term(), module()}]
      def __casts__, do: unquote(Macro.escape(own_casts))

      unquote(nil_clauses(nil?))
      unquote_splicing(cast_clauses(casts, :load))
      unquote_splicing(cast_clauses(casts, :dump))
      unquote(fallback_clauses(fallback?))
    end
  end

  ## Private functions

  defp validate_opts!(opts) do
    unknown = Keyword.keys(opts) -- Keyword.keys(@default_opts)

    if unknown != [] do
      raise ArgumentError, "unknown Dowser.Client.Codec.Builder option(s): #{inspect(unknown)}"
    end

    Keyword.merge(@default_opts, opts)
  end

  defp inherited_casts(nil), do: []
  defp inherited_casts(inherit), do: inherit.__casts__()

  defp cast_clauses(casts, fun) do
    for {pattern, field_module} <- casts do
      quote do
        def unquote(fun)(value, unquote(pattern) = field) do
          unquote(field_module).unquote(fun)(value, field)
        end
      end
    end
  end

  defp nil_clauses(false), do: []

  defp nil_clauses(true) do
    quote do
      def load(nil, _field), do: nil
      def dump(nil, _field), do: nil
    end
  end

  defp fallback_clauses(false), do: []

  defp fallback_clauses(true) do
    quote do
      def load(value, _field), do: value
      def dump(value, _field), do: value
    end
  end
end
