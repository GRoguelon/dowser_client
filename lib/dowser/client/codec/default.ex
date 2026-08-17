defmodule Dowser.Client.Codec.Default do
  @moduledoc """
  The built-in, backend-agnostic `Dowser.Client.Codec`.

  `decode/2` applies `opts[:key_fn]` (resolved from `:keys` by
  `Dowser.Client.Request`) to every key of the decoded body — recursively,
  through maps, lists and `MapSet`s (an ndjson body decodes to a *list* of maps, so the
  transform must recurse into it too, not just top-level maps). Any other
  term (a scalar, `nil`, ...) passes through unchanged.

  `encode/2` does no casting of its own — `dowser_client` has no
  backend-specific value-casting knowledge; see `Dowser.Client.Codec`.
  """

  alias Dowser.CoreExt.Keyable

  ## Behaviours

  @behaviour Dowser.Client.Codec

  ## Public functions

  @impl Dowser.Client.Codec
  def encode(value, _opts) do
    {:ok, value}
  end

  @impl Dowser.Client.Codec
  def decode(value, opts) do
    key_fn = Keyword.fetch!(opts, :key_fn)

    {:ok, Keyable.transform_keys(value, key_fn)}
  end
end
