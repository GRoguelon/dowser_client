defmodule Dowser.Client.JSON do
  @moduledoc """
  JSON encoding and decoding, on Elixir's built-in `JSON` module.

  No dependency and no choice to make: `JSON` ships with Elixir 1.18+, which
  `dowser_client` already requires.

  Decoding always yields **string-keyed** maps, deliberately. Casting a
  response beyond plain JSON — atom keys, `"2026-09-18"` into `~D[2026-09-18]`
  — needs to know which document each value came from and which mapping applies
  to it, which is backend-specific knowledge `dowser_client` doesn't have. That
  is an optional second pass over the decoded body, configured with
  `:keys`/`:decoder`; see `Dowser.Client.Decoder`.

  Both functions return a `Dowser.Client.JSON.Error` rather than raising, so a
  malformed payload is an ordinary `{:error, exception}` result.
  """

  alias Dowser.Client.JSON.Error

  ## Public functions

  @doc "Encodes `term` into JSON `iodata`."
  @spec encode(term()) :: {:ok, iodata()} | {:error, Error.t()}
  def encode(term) do
    {:ok, JSON.encode_to_iodata!(term)}
  rescue
    exception -> {:error, %Error{reason: exception, operation: :encode}}
  end

  @doc "Decodes a JSON binary into a term with string keys."
  @spec decode(binary()) :: {:ok, term()} | {:error, Error.t()}
  def decode(binary) do
    case JSON.decode(binary) do
      {:ok, term} -> {:ok, term}
      {:error, reason} -> {:error, %Error{reason: reason, operation: :decode}}
    end
  rescue
    exception -> {:error, %Error{reason: exception, operation: :decode}}
  end
end
