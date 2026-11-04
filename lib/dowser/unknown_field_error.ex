defmodule Dowser.UnknownFieldError do
  @moduledoc """
  A document holds a field its mapping doesn't declare, under
  `unknown_fields: :raise`.

  `:path` is the field, from the document's root (`["author", "nickname"]`),
  and `:direction` whether it was met while loading a document (`:load`) or
  dumping one (`:dump`).

  By default (`unknown_fields: :keep`) such a field is left as it is. `:raise`
  is for the applications — and the test suites — that would rather know: a
  field the mapping doesn't declare is one an index with `"dynamic": "strict"`
  rejects, or one another client wrote without the mapping saying so.
  """

  @type t :: %__MODULE__{path: [String.t()], direction: :load | :dump}

  defexception [:path, :direction]

  @impl true
  def message(%__MODULE__{path: path, direction: direction}) do
    verb = if direction == :dump, do: "dumping", else: "loading"

    "field #{inspect(Enum.join(path, "."))} is not in the mapping " <>
      "(#{verb} a document with unknown_fields: :raise)"
  end
end
