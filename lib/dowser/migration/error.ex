defmodule Dowser.Migration.Error do
  @moduledoc """
  A migration couldn't be planned or run: the cluster isn't in the state the
  migrations expect, an operation is invalid against the index's mapping, an
  operation needs a copy the migrator wasn't allowed to make, or a request
  failed.

  Raised before any change when the problem is found while planning.
  """

  @type t :: %__MODULE__{message: String.t()}

  defexception [:message]
end
