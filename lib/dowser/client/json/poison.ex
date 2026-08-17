defmodule Dowser.Client.JSON.Poison do
  @moduledoc """
  JSON adapter backed by the [`Poison`](https://hex.pm/packages/poison) library.

  `Poison` is an optional dependency. Add `{:poison, "~> 6.0"}` to your deps to
  use this adapter; a helpful error is raised at call time if it is missing.

  Any `Poison` option (e.g. `keys: :atoms` for `decode/2`) can be passed
  through `opts`.
  """

  ## Behaviours

  @behaviour Dowser.Client.JSON.Adapter

  ## Public functions

  if Code.ensure_loaded?(Poison) do
    @impl Dowser.Client.JSON.Adapter
    def encode(term, opts), do: Poison.encode(term, opts)

    @impl Dowser.Client.JSON.Adapter
    def decode(binary, opts), do: Poison.decode(binary, opts)
  else
    @impl Dowser.Client.JSON.Adapter
    def encode(_term, _opts), do: missing_dependency!()

    @impl Dowser.Client.JSON.Adapter
    def decode(_binary, _opts), do: missing_dependency!()

    ## Private functions

    defp missing_dependency! do
      raise Dowser.Client.Error,
        reason: {:missing_dependency, :poison},
        message: """
        #{inspect(__MODULE__)} requires the :poison dependency.

        Add it to your deps:

            {:poison, "~> 6.0"}
        """
    end
  end
end
