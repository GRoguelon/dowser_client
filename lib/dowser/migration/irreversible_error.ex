defmodule Dowser.Migration.IrreversibleError do
  @moduledoc """
  A `change/0` migration holds an operation that can't be inverted without
  more information — a `drop_index` without its body, a `remove` without the
  field's definition, a `set`, `unset` or `modify` without `from:`, a `script`
  without `reverse:`. Raised when a rollback is planned, before any change.
  """

  @type t :: %__MODULE__{message: String.t()}

  defexception [:message]
end
