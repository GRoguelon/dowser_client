defmodule Dowser.Client.NDJSON do
  @moduledoc """
  Encode and decode [NDJSON](https://github.com/ndjson/ndjson-spec)
  (newline-delimited JSON).

  NDJSON does no JSON work itself: every line is encoded/decoded through a
  `Dowser.Client.JSON.Adapter` module passed in as an argument. That way NDJSON
  always honours the same JSON codec — and the same per-request options — that
  the rest of Dowser is configured with (Elixir's built-in `JSON`, `Jason` or
  `Poison`).

  `encode/3` joins the encoded entries with `"\\n"` and appends a trailing
  newline (required by, e.g., bulk-indexing and multi-search style APIs).
  `decode/3` splits on newlines and skips blank lines, so a trailing newline —
  or the odd empty line — is handled transparently.

  Both functions short-circuit, returning the JSON adapter's `{:error, reason}`
  as soon as a single line fails.

  ## Examples

      iex> adapter = Dowser.Client.JSON.Jason
      iex> {:ok, iodata} = Dowser.Client.NDJSON.encode([%{"a" => 1}, %{"b" => 2}], adapter)
      iex> IO.iodata_to_binary(iodata)
      ~s({"a":1}\\n{"b":2}\\n)
      iex> Dowser.Client.NDJSON.decode(~s({"a":1}\\n{"b":2}\\n), adapter)
      {:ok, [%{"a" => 1}, %{"b" => 2}]}
  """

  import Dowser.Blank, only: [blank?: 1]

  ## Typespecs

  @typedoc "A module implementing `Dowser.Client.JSON.Adapter`."
  @type adapter :: module()

  ## Public functions

  @doc """
  Encodes a list of terms into NDJSON `iodata`, one JSON document per line with
  a trailing newline. `opts` are forwarded to the adapter's `encode/2`.
  """
  @spec encode([term()], adapter(), keyword()) :: {:ok, iodata()} | {:error, term()}
  def encode(entries, adapter, opts \\ []) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case adapter.encode(entry, opts) do
        {:ok, iodata} ->
          {:cont, {:ok, [acc, iodata, "\n"]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  @doc """
  Decodes an NDJSON binary into a list of terms, one per non-blank line. `opts`
  are forwarded to the adapter's `decode/2`.
  """
  @spec decode(binary(), adapter(), keyword()) :: {:ok, [term()]} | {:error, term()}
  def decode(binary, adapter, opts \\ []) when is_binary(binary) do
    binary
    |> String.split("\n")
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      if blank?(line) do
        {:cont, {:ok, acc}}
      else
        case adapter.decode(line, opts) do
          {:ok, term} -> {:cont, {:ok, [term | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, terms} ->
        {:ok, Enum.reverse(terms)}

      {:error, _reason} = error ->
        error
    end
  end
end
