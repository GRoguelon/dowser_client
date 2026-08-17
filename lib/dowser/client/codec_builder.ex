defmodule Dowser.Client.CodecBuilder do
  @moduledoc """
  Builds a `load/2` + `dump/2` dispatcher from a list of `Dowser.Client.Field`
  mappings.

  `use Dowser.Client.CodecBuilder` turns a module into a `Dowser.Client.Field`-
  shaped dispatcher: it exposes a `cast/2` macro to declare, for a pattern
  matched against the second argument (typically field metadata), which
  `Dowser.Client.Field` module handles it. At compile time this expands into
  plain `load/2`/`dump/2` function clauses — one pattern-matched clause per
  `cast/2`, dispatching straight to the field module, with no indirection at
  runtime.

  A module built this way implements `Dowser.Client.Field`'s per-*value*
  contract (`load/2`/`dump/2`) — it is **not** a `Dowser.Client.Codec` and
  can't be set directly as `:codec_adapter`, which casts a whole *body*
  (`encode/2`/`decode/2`). See the bridging example at the bottom of this
  moduledoc, and `Dowser.Client.Codec` for the full `:codec_adapter` contract.

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
        use Dowser.Client.CodecBuilder

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

  ## From field codec to `:codec_adapter`

  Bridging `FieldCodec.load/2`/`dump/2` into something usable as
  `:codec_adapter` means walking a document alongside its mapping/schema —
  backend-specific knowledge `dowser_client` doesn't have, so it can't
  provide that walk generically. A backend package writes its own thin
  `Dowser.Client.Codec`:

      defmodule Dowser.Elasticsearch.Codec do
        @behaviour Dowser.Client.Codec

        alias Dowser.CoreExt.Keyable
        alias Dowser.Elasticsearch.FieldCodec

        @impl true
        def decode(body, opts) do
          key_fn = Keyword.fetch!(opts, :key_fn)
          # `walk_mapping/2` is the backend-specific part: recurse through
          # `body` alongside its index mapping, calling
          # `FieldCodec.load/2` with each value's own field metadata.
          {:ok, body |> Keyable.transform_keys(key_fn) |> walk_mapping(&FieldCodec.load/2)}
        end

        @impl true
        def encode(body, _opts) do
          {:ok, walk_mapping(body, &FieldCodec.dump/2)}
        end
      end

  See `Dowser.Client.Codec` for the full `:codec_adapter` contract, including
  `opts[:key_fn]`.

  ## Options

    * `:inherit` — a module built with `Dowser.Client.CodecBuilder` whose `cast/2`
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
      import Dowser.Client.CodecBuilder, only: [cast: 2]

      @behaviour Dowser.Client.Field

      Module.register_attribute(__MODULE__, :dowser_codec_casts, accumulate: true)
      @dowser_codec_inherit unquote(inherit)
      @dowser_codec_fallback? unquote(Keyword.fetch!(opts, :fallback))
      @dowser_codec_nil? unquote(Keyword.fetch!(opts, nil))

      @before_compile Dowser.Client.CodecBuilder
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
      raise ArgumentError, "unknown Dowser.Client.CodecBuilder option(s): #{inspect(unknown)}"
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
