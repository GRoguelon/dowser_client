defmodule Dowser.TestPost do
  @moduledoc """
  A hand-written document module (`Dowser.Schema`) for the test suite: what
  `use ...Schema` will generate, written out.
  """

  @behaviour Dowser.Schema

  defstruct [:title, :published_at, :meta]

  @mapping %{
    "properties" => %{
      "title" => %{"type" => "text"},
      "published_at" => %{"type" => "date", "format" => "strict_date_time"}
    }
  }

  @impl true
  def __schema__(:mapping), do: @mapping

  @impl true
  def __load__(source, opts) do
    source = Dowser.Source.load(source, @mapping, Keyword.put(opts, :unknown_fields, :raise))

    %__MODULE__{
      title: source["title"],
      published_at: source["published_at"],
      meta: Keyword.get(opts, :meta)
    }
  end

  @impl true
  def __dump__(%__MODULE__{} = post, opts) do
    post
    |> Map.from_struct()
    |> Map.delete(:meta)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Dowser.Source.dump(@mapping, opts)
  end
end

defmodule Dowser.TestMappings do
  @moduledoc "A mapping source (`Dowser.Mapping`) for the test suite."

  @behaviour Dowser.Mapping

  @impl true
  def fetch_mapping("posts", _repo_config) do
    {:ok, %{"properties" => %{"ip" => %{"type" => "ip"}}}}
  end

  def fetch_mapping("broken", _repo_config), do: {:error, :timeout}
  def fetch_mapping(_index, _repo_config), do: {:ok, nil}
end

defmodule Dowser.TestUpcase do
  @moduledoc "A `Dowser.Type` module for the test suite: upcases `text`."

  @behaviour Dowser.Type

  @impl true
  def load(value, %{"type" => "text"}) when is_binary(value), do: String.upcase(value)
  def load(value, field), do: Dowser.Type.load(value, field)

  @impl true
  def dump(value, field), do: Dowser.Type.dump(value, field)
end

defmodule Dowser.TestCacher do
  @moduledoc "A mapping cacher for the test suite — not started unless a test starts it."

  use Dowser.MappingCacher, otp_app: :dowser_client
end

defmodule Dowser.TestMockRepo do
  @moduledoc """
  A hand-written stand-in for a repo — what a Mox mock of `Dowser.Repo` is:
  a module implementing `request/4`, without `use Dowser.Repo`.
  """

  @behaviour Dowser.Repo

  @impl true
  def request(method, path, _body, _opts) do
    {:ok, %Dowser.Client.Response{status: 200, headers: %{}, body: %{"mocked" => [method, path]}}}
  end
end
