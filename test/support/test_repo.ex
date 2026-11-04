defmodule Dowser.TestRepo do
  @moduledoc """
  A repo for the test suite, configured under `:dowser_client` itself:
  `Application.put_env(:dowser_client, Dowser.TestRepo, endpoint: ...)`.
  """

  use Dowser.Repo, otp_app: :dowser_client
end

defmodule Dowser.TestRepo.WithInit do
  @moduledoc """
  A repo whose `init/2` adds the auth and records how it was called, the way
  an application reads a secret that can't live in config files.
  """

  use Dowser.Repo, otp_app: :dowser_client

  @impl true
  def init(type, config) do
    send(Keyword.get(config, :test_pid, self()), {:init, type})

    {:ok, Keyword.put(config, :auth, {:bearer, "from-init"})}
  end
end

defmodule Dowser.TestRepo.Verified do
  @moduledoc "A repo whose `verify/1` reports what its endpoint says it is."

  use Dowser.Repo, otp_app: :dowser_client

  @impl true
  def verify(context) do
    case Keyword.get(context.http_opts, :engine) do
      nil ->
        {:error, :not_the_expected_engine}

      engine ->
        {:ok, engine}
    end
  end
end
