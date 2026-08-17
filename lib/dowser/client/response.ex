defmodule Dowser.Client.Response do
  @moduledoc """
  A normalized HTTP response.

  HTTP adapters build responses with `new/3`, which normalizes headers into a
  map of downcased string keys to string values (duplicate header names are
  folded into a single comma-joined value).

  `:body` starts as the raw payload binary. `decode/2` is the decoding phase: it
  turns the body into a decoded term according to the request `:format` (`:json`
  or `:ndjson`); `:raw` leaves it a binary. `Dowser.Client.request/4` runs the
  decode phase automatically after the adapter returns.
  """

  alias Dowser.Client.Codec.Error, as: CodecError
  alias Dowser.Client.JSON.Error, as: JSONError
  alias Dowser.Client.NDJSON
  alias Dowser.Client.Request

  ## Structure

  @enforce_keys [:status]
  defstruct status: nil, headers: %{}, body: ""

  ## Typespecs

  @type headers :: %{optional(String.t()) => String.t()}
  @type format :: :json | :ndjson | :raw

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          headers: headers(),
          body: term()
        }

  ## Public functions

  @doc """
  Builds a response, normalizing `headers` into a map of downcased string keys
  and string values.

  `headers` may be any enumerable of `{name, value}` pairs (names/values as
  binaries or charlists). Duplicate names are folded into one comma-joined value.
  """
  @spec new(non_neg_integer(), Enumerable.t(), term()) :: t()
  def new(status, headers, body) do
    %__MODULE__{status: status, headers: normalize_headers(headers), body: body}
  end

  def decode(%__MODULE__{} = response, %Request{} = request) do
    case decode_body(response.body, request) do
      {:ok, body} ->
        {:ok, %{response | body: body}}

      {:error, _reason} = error ->
        error
    end
  end

  ## Private functions — headers

  defp normalize_headers(headers) do
    Enum.reduce(headers, %{}, fn {name, value}, acc ->
      name = name |> to_string() |> String.downcase()
      value = to_string(value)
      Map.update(acc, name, value, &(&1 <> ", " <> value))
    end)
  end

  ## Private functions — body

  defp decode_body(body, %{resp_format: resp_format})
       when resp_format == :raw or body in [nil, ""] do
    {:ok, body}
  end

  defp decode_body(body, %{resp_format: :json} = request) do
    case request.json_adapter.decode(body, request.json_opts) do
      {:ok, result} ->
        cast(result, request)

      {:error, reason} ->
        {:error, %JSONError{reason: reason, operation: :decode, adapter: request.json_adapter}}
    end
  rescue
    exception ->
      {:error, %JSONError{reason: exception, operation: :decode, adapter: request.json_adapter}}
  end

  defp decode_body(body, %{resp_format: :ndjson} = request) do
    case NDJSON.decode(body, request.json_adapter, request.json_opts) do
      {:ok, result} ->
        cast(result, request)

      {:error, reason} ->
        {:error, %JSONError{reason: reason, operation: :decode, adapter: request.json_adapter}}
    end
  rescue
    exception ->
      {:error, %JSONError{reason: exception, operation: :decode, adapter: request.json_adapter}}
  end

  ## Private functions — casting

  defp cast(term, %{codec_adapter: nil}) do
    {:ok, term}
  end

  defp cast(term, %{codec_adapter: codec_adapter, codec_opts: codec_opts}) do
    codec_adapter.decode(term, codec_opts)
  rescue
    exception ->
      {:error, %CodecError{reason: exception, codec: codec_adapter, operation: :decode}}
  end
end
