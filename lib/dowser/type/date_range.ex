defmodule Dowser.Type.DateRange do
  @moduledoc """
  `date_range` — the `%{"gte" => _, "lte" => _}` object form <-> a `Date.Range`.

  Only a field formatted `strict_date` is cast, since that is the one whose
  bounds are dates and nothing more — what a `Date.Range` holds. Its bounds are
  read with `Date.from_iso8601/1`.

  Anything else is returned as it is stored: a field with another format (or
  none, which the backend reads as `strict_date_optional_time||epoch_millis`),
  exclusive `gt`/`lt` bounds, a bound that isn't a date, and on the way out a
  `Date.Range` whose step isn't 1.

      iex> Dowser.Type.DateRange.load(
      ...>   %{"gte" => "2026-08-01", "lte" => "2026-08-11"},
      ...>   %{"type" => "date_range", "format" => "strict_date"}
      ...> )
      Date.range(~D[2026-08-01], ~D[2026-08-11])

      iex> Dowser.Type.DateRange.load(
      ...>   %{"gte" => "2026-08-01T00:00:00Z", "lte" => "2026-08-11T00:00:00Z"},
      ...>   %{"type" => "date_range"}
      ...> )
      %{"gte" => "2026-08-01T00:00:00Z", "lte" => "2026-08-11T00:00:00Z"}
  """

  ## Behaviours

  @behaviour Dowser.Type

  ## Public functions

  @impl true
  def load(%{"gte" => gte, "lte" => lte} = value, %{"format" => "strict_date"})
      when map_size(value) == 2 and is_binary(gte) and is_binary(lte) do
    with {:ok, first} <- Date.from_iso8601(gte),
         {:ok, last} <- Date.from_iso8601(lte),
         true <- Date.compare(first, last) != :gt do
      Date.range(first, last)
    else
      _error ->
        value
    end
  end

  def load(value, _field) do
    value
  end

  @impl true
  def dump(%Date.Range{step: 1} = date_range, %{"format" => "strict_date"}) do
    %{"gte" => Date.to_iso8601(date_range.first), "lte" => Date.to_iso8601(date_range.last)}
  end

  def dump(value, _field) do
    value
  end
end
