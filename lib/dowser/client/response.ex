defmodule Dowser.Client.Response do
  @moduledoc """
  A normalized HTTP response.

  HTTP adapters build responses with `new/3`, which normalizes headers into a
  map of downcased string keys to string values (duplicate header names are
  folded into a single comma-joined value).

  `:body` starts as the raw payload binary. `decode/2` is the decoding phase: it
  turns the body into a decoded term according to the request `:format` (`:json`
  or `:ndjson`); `:raw` leaves it a binary. Decoding always yields string-keyed
  maps, after which `:keys`/`:decoder` — when either is set — get a second pass
  over that term (see `Dowser.Client.Decoder`).
  `Dowser.Client.request/4` runs the decode phase automatically once the
  transport returns.
  """

  alias Dowser.Client.Decoder
  alias Dowser.Client.Error
  alias Dowser.Client.JSON
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

  @doc """
  Runs the decode phase: JSON/NDJSON per the request's `:resp_format`, then the
  optional second pass from `:keys`/`:decoder`.
  """
  @spec decode(t(), Request.t()) :: {:ok, t()} | {:error, Exception.t()}
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
    with {:ok, term} <- JSON.decode(body) do
      cast(term, request)
    end
  end

  # An ndjson payload is cast per entry, so the decoder goes to `NDJSON` rather
  # than running over the whole list afterwards.
  defp decode_body(body, %{resp_format: :ndjson} = request) do
    NDJSON.decode(body, key_fn: request.key_fn, decoder: request.decoder)
  rescue
    exception -> {:error, %Error{reason: {:decode_failed, exception}}}
  end

  ## Private functions — the second pass

  defp cast(term, %{key_fn: key_fn, decoder: decoder}) do
    if Decoder.needed?(key_fn, decoder) do
      {:ok, Decoder.run(term, key_fn, decoder)}
    else
      {:ok, term}
    end
  rescue
    exception -> {:error, %Error{reason: {:decode_failed, exception}}}
  end
end
