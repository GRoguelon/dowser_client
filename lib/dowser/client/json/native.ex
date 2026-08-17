defmodule Dowser.Client.JSON.Native do
  @moduledoc """
  JSON adapter backed by Elixir's built-in `JSON` module.

  Requires no dependency. The built-in `JSON` module ships with Elixir 1.18+,
  which `dowser_client` already requires, so it's always available.

  The built-in codec takes no options, so `opts` is ignored.
  """

  ## Behaviours

  @behaviour Dowser.Client.JSON.Adapter

  ## Public functions

  @impl Dowser.Client.JSON.Adapter
  def encode(term, _opts) do
    {:ok, JSON.encode_to_iodata!(term)}
  rescue
    error -> {:error, error}
  end

  @impl Dowser.Client.JSON.Adapter
  def decode(binary, _opts) do
    {:ok, JSON.decode!(binary)}
  rescue
    error -> {:error, error}
  end
end
