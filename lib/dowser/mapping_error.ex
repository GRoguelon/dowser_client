defmodule Dowser.MappingError do
  @moduledoc """
  The mapping a document had to be cast against could not be fetched.

  Casting is what turns a `date` field into a `DateTime`, a `date_range` into a
  `Date.Range`, and back. Without the mapping, `Dowser.Codec` has nothing to
  dispatch on and every value passes through as the raw JSON term — so the
  *type* a caller gets back would depend on whether a `_mapping` request
  happened to succeed. That request is a call like any other, most likely to
  fail exactly when the cluster is overloaded, which is when code is least able
  to cope with a `%{"gte" => ..., "lte" => ...}` where it expects a
  `Date.Range`.

  So a failed fetch raises this by default, and the request fails with it
  rather than quietly returning uncast values. `:index` is the index whose
  mapping was wanted and `:reason` what the fetch returned.

  See `Dowser.Codec`'s `:mapping_failure` option for the other policies
  (`:warn`, `:ignore`), and `Dowser.MappingCacher` for mappings that are never
  fetched and so can never fail.
  """

  @type t :: %__MODULE__{index: term(), reason: term()}

  defexception [:index, :reason]

  @impl true
  def message(%__MODULE__{index: index, reason: reason}) do
    "could not fetch the mapping for index #{inspect(index)}, so its values " <>
      "would have been left uncast: #{inspect(reason)}"
  end
end
