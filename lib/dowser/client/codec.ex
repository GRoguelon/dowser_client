defmodule Dowser.Client.Codec do
  @moduledoc """
  Behaviour for casting a whole request/response body, wired onto a
  `Dowser.Client.Config`/request as `:codec_adapter`.

  Unlike `Dowser.Client.Field` (which casts *one* value), a `Codec` sees the
  entire decoded body and is responsible for everything that happens to it
  beyond plain JSON decoding:

    * `decode/2` — casts a decoded response body (already key-cast per
      `opts[:key_fn]`, see below) into whatever richer shape the codec wants.
    * `encode/2` — the reverse, casting a request body before it's
      JSON-encoded.

  Both receive `opts` — the resolved `:codec_opts`, with two entries always
  added by `Dowser.Client.Request`: `:key_fn` (the key-casting function
  resolved from `:keys`) and `:config` (the resolved `Dowser.Client.Config`).
  `dowser_client`'s default (`Dowser.Client.Codecs.DefaultCodec`) only applies
  `:key_fn` via `Dowser.CoreExt.Keyable.transform_keys/2` and otherwise passes
  the body through unchanged — use it as a reference implementation.

  `dowser_client` has no backend-specific knowledge of its own, so it ships no
  other implementation. A backend package (e.g. `dowser_elasticsearch`) that
  wants per-field value casting (dates, geo points, ...) implements its own
  `Codec` that walks the body against its mapping/schema — backend-specific
  knowledge `dowser_client` doesn't have — dispatching each field to a
  `Dowser.Client.CodecBuilder`-built module's `load/2`/`dump/2`. See
  `Dowser.Client.CodecBuilder` for that half of the pattern.
  """

  @callback encode(value :: term(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback decode(value :: term(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
end
