defmodule Dowser.Client.JSON.Jason do
  @moduledoc """
  JSON adapter backed by the [`Jason`](https://hex.pm/packages/jason) library.

  `Jason` is an optional dependency. Add `{:jason, "~> 1.4"}` to your deps to
  use this adapter; a helpful error is raised at call time if it is missing.

  `encode/2` uses `Jason.encode_to_iodata/2` to avoid building an intermediate
  binary. Any `Jason` option (e.g. `keys: :atoms` for `decode/2`) can be passed
  through `opts`.
  """

  ## Behaviours

  @behaviour Dowser.Client.JSON.Adapter

  ## Public functions

  if Code.ensure_loaded?(Jason) do
    @impl Dowser.Client.JSON.Adapter
    def encode(term, opts), do: Jason.encode_to_iodata(term, opts)

    @impl Dowser.Client.JSON.Adapter
    def decode(binary, opts), do: Jason.decode(binary, opts)
  else
    @impl Dowser.Client.JSON.Adapter
    def encode(_term, _opts), do: missing_dependency!()

    @impl Dowser.Client.JSON.Adapter
    def decode(_binary, _opts), do: missing_dependency!()

    ## Private functions

    defp missing_dependency! do
      raise Dowser.Client.Error,
        reason: {:missing_dependency, :jason},
        message: """
        #{inspect(__MODULE__)} requires the :jason dependency.

        Add it to your deps:

            {:jason, "~> 1.4"}
        """
    end
  end
end
