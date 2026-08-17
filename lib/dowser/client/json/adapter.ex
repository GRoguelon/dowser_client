defmodule Dowser.Client.JSON.Adapter do
  @moduledoc """
  Behaviour implemented by every JSON codec.

  Adapters convert between Elixir terms and JSON. `encode/2` returns `iodata`
  (cheap to feed straight into a request body); `decode/2` takes the raw
  response binary. Both accept a keyword list of codec-specific options and
  return a tagged tuple instead of raising, so the caller decides how to handle
  failures.

  Decoding yields string-keyed maps unless the underlying codec is told
  otherwise through `opts`.

  Bundled implementations:

    * `Dowser.Client.JSON.Native` — Elixir's built-in `JSON` module (no dependency)
    * `Dowser.Client.JSON.Jason` — the `Jason` library (optional dependency)
    * `Dowser.Client.JSON.Poison` — the `Poison` library (optional dependency)
  """

  ## Typespecs

  @type opts :: keyword()

  ## Behaviour callbacks

  @callback encode(term(), opts()) :: {:ok, iodata()} | {:error, term()}
  @callback decode(binary(), opts()) :: {:ok, term()} | {:error, term()}
end
