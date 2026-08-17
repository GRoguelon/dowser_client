defmodule Dowser.Client.CodecBuilder do
  @moduledoc """
  Deprecated alias for `Dowser.Client.Codec.Builder`.

  `use Dowser.Client.CodecBuilder` still works and behaves exactly like
  `use Dowser.Client.Codec.Builder`, which it delegates to. It will be removed
  in a future release.
  """
  @moduledoc deprecated: "Use Dowser.Client.Codec.Builder instead."

  ## Macros

  @doc false
  @deprecated "Use Dowser.Client.Codec.Builder instead"
  defmacro __using__(opts) do
    quote do
      use Dowser.Client.Codec.Builder, unquote(opts)
    end
  end
end
