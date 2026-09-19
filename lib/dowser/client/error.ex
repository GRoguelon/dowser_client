defmodule Dowser.Client.Error do
  @moduledoc """
  Generic Dowser client error.

  Used for failures that are neither HTTP transport nor codec specific —
  e.g. an unknown context, an invalid
  `:auth`/`:format`/`:keys`/`:decoder`/`:encoder`/`:encode`/`:retry`, or a
  `:keys`, `:decoder` or `:encoder` function that raised while casting a body. Transport failures are `Dowser.Client.HTTP.Error`; JSON encoding and
  decoding failures are `Dowser.Client.JSON.Error`.
  """

  alias Dowser.Client.Decoder

  @type t :: %__MODULE__{reason: term(), message: String.t() | nil}

  defexception [:reason, :message]

  @impl true
  def message(%__MODULE__{message: message}) when is_binary(message), do: message

  def message(%__MODULE__{reason: {:unknown_context, name}}) do
    "unknown context #{inspect(name)}"
  end

  def message(%__MODULE__{reason: {:invalid_auth, auth}}) do
    "invalid :auth #{inspect(auth)}, expected {:basic, value} | {:basic, username, password} | " <>
      "{:api_key, value} | {:api_key, id, api_key} | {:bearer, token} | {:header, name, value}"
  end

  def message(%__MODULE__{reason: {:invalid_keys, value}}) do
    "invalid :keys option #{inspect(value)}, expected :strings, :atoms, :atoms! " <>
      "or a function of arity 1" <> did_you_mean(value)
  end

  def message(%__MODULE__{reason: {:invalid_decoder, value}}) do
    "invalid :decoder option #{inspect(value)}, expected a function of arity 2 " <>
      "taking (body, opts), or a module exporting decode/2"
  end

  def message(%__MODULE__{reason: {:decode_failed, exception}}) do
    "decoding the response body failed: #{Exception.message(exception)}"
  end

  def message(%__MODULE__{reason: {:invalid_encoder, value}}) do
    "invalid :encoder option #{inspect(value)}, expected a function of arity 2 " <>
      "taking (source, opts), or a module exporting encode/2"
  end

  def message(%__MODULE__{reason: {:invalid_encode, value}}) do
    "invalid :encode option #{inspect(value)}, expected true, false, a path " <>
      "(a list of keys) or a list of paths"
  end

  def message(%__MODULE__{reason: {:encode_failed, exception}}) do
    "encoding the request body failed: #{Exception.message(exception)}"
  end

  def message(%__MODULE__{reason: {:invalid_ndjson, body}}) do
    "an :ndjson body must be a list of terms, one per line, got: #{inspect(body)}"
  end

  def message(%__MODULE__{reason: {:invalid_format, format}}) do
    "invalid format #{inspect(format)}, expected :json, :ndjson or :raw"
  end

  def message(%__MODULE__{reason: :conflicting_formats}) do
    ":format is mutually exclusive with :req_format and :resp_format"
  end

  def message(%__MODULE__{reason: {:invalid_retry, value}}) do
    "invalid :retry option #{inspect(value)}, expected a keyword list or false"
  end

  def message(%__MODULE__{reason: {:removed_option, option}}) do
    "#{inspect(option)} was removed in 0.2.0 — #{removed_option_hint(option)}. " <>
      "See UPGRADE_GUIDE_0_2.md."
  end

  def message(%__MODULE__{reason: reason}), do: "Dowser client error: #{inspect(reason)}"

  @doc """
  What replaced an option removed in 0.2.0, as a sentence fragment.

  Shared by this module's messages and the warnings `Dowser.Client.Request`
  logs for the removed options it tolerates.
  """
  @spec removed_option_hint(atom()) :: String.t()
  def removed_option_hint(option)

  def removed_option_hint(:config), do: "the option is now :context"

  def removed_option_hint(:http_adapter) do
    "HTTP is always OTP's :httpc now, configured with :profile/:profile_opts, " <>
      "and stubbed with Dowser.Client.HTTP.Stub.stub/1"
  end

  def removed_option_hint(:codec_adapter) do
    "use :decoder to cast a response and :encoder with :encode to cast a document source"
  end

  def removed_option_hint(:codec_opts) do
    "an encoder/decoder carries its own options, as in decoder: {MyDecoder, mapping: mapping}"
  end

  def removed_option_hint(option) when option in [:json_adapter, :json_opts] do
    "JSON is Elixir's built-in JSON module, with nothing to configure"
  end

  def removed_option_hint(option), do: "see the changelog for #{inspect(option)}"

  ## Private functions

  defp did_you_mean(value) do
    case Decoder.suggestion(value) do
      nil -> ""
      candidate -> " — did you mean #{inspect(candidate)}?"
    end
  end
end
