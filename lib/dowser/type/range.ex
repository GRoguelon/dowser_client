defmodule Dowser.Type.Range do
  @moduledoc """
  `integer_range` and `long_range` — the `%{"gte" => _, "lte" => _}` object
  form <-> an Elixir `Range` (`first..last//1`).

  Only what a `Range` holds exactly is cast: integer `gte` and `lte` bounds,
  `gte` no greater than `lte`. Anything else is returned as it is stored — an
  open-ended range (one bound only), exclusive `gt`/`lt` bounds, non-integer
  bounds, and on the way out a `Range` whose step isn't 1.

      iex> Dowser.Type.Range.load(%{"gte" => 1, "lte" => 10}, %{"type" => "integer_range"})
      1..10

      iex> Dowser.Type.Range.load(%{"gte" => 1}, %{"type" => "integer_range"})
      %{"gte" => 1}

      iex> Dowser.Type.Range.dump(1..10, %{"type" => "long_range"})
      %{"gte" => 1, "lte" => 10}
  """

  ## Behaviours

  @behaviour Dowser.Type

  ## Public functions

  @impl true
  def load(%{"gte" => gte, "lte" => lte} = value, _field)
      when map_size(value) == 2 and is_integer(gte) and is_integer(lte) and gte <= lte do
    Range.new(gte, lte, 1)
  end

  def load(value, _field) do
    value
  end

  @impl true
  def dump(%Range{first: first, last: last, step: 1}, _field) when first <= last do
    %{"gte" => first, "lte" => last}
  end

  def dump(value, _field) do
    value
  end
end
