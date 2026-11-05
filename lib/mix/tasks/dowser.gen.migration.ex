defmodule Mix.Tasks.Dowser.Gen.Migration do
  @shortdoc "Generates a Dowser migration"

  @moduledoc """
  Generates a migration for a repo.

      $ mix dowser.gen.migration add_status_to_events
      $ mix dowser.gen.migration add_status_to_events -r MyApp.Search

  writes `priv/dowser/migrations/<UTC timestamp>_add_status_to_events.exs` —
  the timestamp is the migration's version — defining
  `MyApp.Search.Migrations.AddStatusToEvents`.

  ## Options

    * `-r`, `--repo` — the repo (the first of `:dowser_repos` by default).
    * `--migrations-path` — where to write it (default: the repo's
      `:migrations_path`, or `priv/dowser/migrations`).
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, rest} =
      OptionParser.parse!(Mix.Dowser.drop_repo_args(args), strict: [migrations_path: :string])

    name =
      case rest do
        [name] ->
          name

        _other ->
          Mix.raise("expected a migration name: mix dowser.gen.migration add_status_to_events")
      end

    unless name =~ ~r/\A[a-z0-9_]+\z/ do
      Mix.raise("a migration name is in snake_case (letters, digits, _), got: #{inspect(name)}")
    end

    Mix.Task.run("app.config")
    [repo | _rest] = Mix.Dowser.repos(args)

    path = Keyword.get_lazy(opts, :migrations_path, fn -> Mix.Dowser.migrations_path(repo) end)
    file = Path.join(path, "#{timestamp()}_#{name}.exs")

    if path |> Path.join("*_#{name}.exs") |> Path.wildcard() != [] do
      Mix.raise("a migration named #{name} already exists in #{path}")
    end

    module = Module.concat([repo, Migrations, Macro.camelize(name)])

    Mix.Generator.create_file(file, """
    defmodule #{inspect(module)} do
      use Dowser.Migration

      def change do
      end
    end
    """)
  end

  defp timestamp do
    %DateTime{year: y, month: m, day: d, hour: hh, minute: mm, second: ss} = DateTime.utc_now()

    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i), do: i |> Integer.to_string() |> String.pad_leading(2, "0")
end
