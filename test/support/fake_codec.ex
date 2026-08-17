defmodule Dowser.Client.FakeCodec do
  @moduledoc """
  Test-only `Dowser.Client.Codec`, usable directly as a `:codec_adapter`.

  Applies `opts[:decode_fun]`/`opts[:encode_fun]` (each `(value, opts) ->
  value`, defaulting to identity) to the whole decoded/encoded body — lets
  tests script a cast, inspect the `opts` they were given (e.g. `:config`,
  `:key_fn`), or raise, without a real backend's casting rules.
  """

  @behaviour Dowser.Client.Codec

  @impl true
  def decode(value, opts) do
    fun = Keyword.get(opts, :decode_fun, fn v, _opts -> v end)
    {:ok, fun.(value, opts)}
  end

  @impl true
  def encode(value, opts) do
    fun = Keyword.get(opts, :encode_fun, fn v, _opts -> v end)
    {:ok, fun.(value, opts)}
  end
end
