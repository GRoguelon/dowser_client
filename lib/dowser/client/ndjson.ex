defmodule Dowser.Client.NDJSON do
  @moduledoc """
  Encode and decode [NDJSON](https://github.com/ndjson/ndjson-spec)
  (newline-delimited JSON), the payload format of bulk-indexing and
  multi-search style APIs.

  Every line goes through `Dowser.Client.JSON`, so NDJSON decodes to the same
  string-keyed maps as a plain JSON body.

  `encode/2` joins the encoded entries with `"\\n"` and appends a trailing
  newline (required by those APIs). `decode/2` splits on newlines and skips
  blank lines, so a trailing newline — or the odd empty line — is handled
  transparently.

  Both short-circuit, returning a `Dowser.Client.JSON.Error` as soon as a
  single line fails.

  ## The casting options

  A line, not the whole payload, is the unit here: each one is its own document,
  action or query. So `:encoder`/`:encode` and `:keys`/`:decoder` are applied
  **per entry** rather than once over the list, which is what lets an encoder
  pattern-match the action lines of a bulk request and leave them alone:

      def encode(%{"index" => _action} = line, _opts), do: line
      def encode(document, opts), do: cast(document, opts[:index])

  A path works the same way, *within* each entry — `encode: ["doc"]` over a bulk
  update payload encodes the `"doc"` of every line that has one, and skips the
  action lines that don't.

  See `Dowser.Client.Encoder` and `Dowser.Client.Decoder` for the options
  themselves; `Dowser.Client.Request`/`Dowser.Client.Response` pass them here.

  ## Examples

      iex> {:ok, iodata} = Dowser.Client.NDJSON.encode([%{"a" => 1}, %{"b" => 2}])
      iex> IO.iodata_to_binary(iodata)
      ~s({"a":1}\\n{"b":2}\\n)
      iex> Dowser.Client.NDJSON.decode(~s({"a":1}\\n{"b":2}\\n))
      {:ok, [%{"a" => 1}, %{"b" => 2}]}
  """

  import Dowser.Blank, only: [blank?: 1]

  alias Dowser.Client.Decoder
  alias Dowser.Client.Encoder
  alias Dowser.Client.Error
  alias Dowser.Client.JSON
  alias Dowser.Client.JSON.Error, as: JSONError

  ## Public functions

  @doc """
  Encodes a list of terms into NDJSON `iodata`, one JSON document per line with
  a trailing newline.

  `opts` may carry `:encoder` and `:encode` (see `Dowser.Client.Encoder`), which
  are applied to each entry before it is encoded.
  """
  @spec encode([term()], keyword()) :: {:ok, iodata()} | {:error, Error.t() | JSONError.t()}
  def encode(entries, opts \\ [])

  def encode(entries, opts) when is_list(entries) do
    {encoder, encode} = encoder(opts)

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case entry |> Encoder.run(encoder, encode) |> JSON.encode() do
        {:ok, iodata} ->
          {:cont, {:ok, [acc, iodata, "\n"]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  # An `:ndjson` body is one JSON document per line, so a single term has no
  # NDJSON representation — that is a caller mistake, not an encoding failure.
  def encode(other, _opts) do
    {:error, %Error{reason: {:invalid_ndjson, other}}}
  end

  @doc """
  Decodes an NDJSON binary into a list of terms, one per non-blank line.

  `opts` may carry `:key_fn` and `:decoder` (see `Dowser.Client.Decoder`), which
  are applied to each decoded entry.
  """
  @spec decode(binary(), keyword()) :: {:ok, [term()]} | {:error, JSONError.t()}
  def decode(binary, opts \\ [])

  def decode(binary, opts) when is_binary(binary) do
    {key_fn, decoder} = decoder(opts)

    binary
    |> String.split("\n")
    |> Enum.reduce_while({:ok, []}, &decode_line(&1, &2, key_fn, decoder))
    |> case do
      {:ok, terms} ->
        {:ok, Enum.reverse(terms)}

      {:error, _reason} = error ->
        error
    end
  end

  ## Private functions

  defp decode_line(line, {:ok, acc}, key_fn, decoder) do
    if blank?(line) do
      {:cont, {:ok, acc}}
    else
      decode_entry(line, acc, key_fn, decoder)
    end
  end

  defp decode_entry(line, acc, key_fn, decoder) do
    case JSON.decode(line) do
      {:ok, term} -> {:cont, {:ok, [Decoder.run(term, key_fn, decoder) | acc]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp encoder(opts) do
    {Keyword.get(opts, :encoder), Keyword.get(opts, :encode, :skip)}
  end

  defp decoder(opts) do
    {Keyword.get(opts, :key_fn), Keyword.get(opts, :decoder)}
  end
end
