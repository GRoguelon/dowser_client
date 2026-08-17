defmodule Dowser.Client.Codecs.DefaultCodec do
  @moduledoc """
  Deprecated alias for `Dowser.Client.Codec.Default`.

  Still usable as a `:codec_adapter` — every callback delegates to
  `Dowser.Client.Codec.Default`. It will be removed in a future release.
  """
  @moduledoc deprecated: "Use Dowser.Client.Codec.Default instead."

  ## Behaviours

  @behaviour Dowser.Client.Codec

  ## Public functions

  @impl Dowser.Client.Codec
  defdelegate encode(value, opts), to: Dowser.Client.Codec.Default

  @impl Dowser.Client.Codec
  defdelegate decode(value, opts), to: Dowser.Client.Codec.Default
end
