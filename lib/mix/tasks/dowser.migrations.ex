defmodule Mix.Tasks.Dowser.Migrations do
  @shortdoc "Lists the Dowser migrations and whether they ran"

  @moduledoc """
  Lists a repo's migrations — its files and what it recorded — with whether
  each ran.

      $ mix dowser.migrations

      MyApp.Search

        Status    Migration ID    Migration Name
      --------------------------------------------------
        up        20261104120000  create_events
        down      20261105090000  add_status

  ## Options

    * `-r`, `--repo` — the repo (repeatable).
    * `--migrations-path` — where the migrations are.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(Mix.Dowser.drop_repo_args(args), strict: [migrations_path: :string])

    Mix.Dowser.start!()
    repos = Mix.Dowser.repos(args)

    Enum.each(repos, fn repo ->
      Mix.Dowser.ensure_repo!(repo)

      opts =
        Keyword.put_new_lazy(opts, :migrations_path, fn -> Mix.Dowser.migrations_path(repo) end)

      rows =
        repo
        |> Dowser.Migrator.migrations(opts)
        |> Enum.map(fn {status, version, name} ->
          "  #{String.pad_trailing(to_string(status), 10)}#{String.pad_trailing(to_string(version), 16)}#{name}\n"
        end)

      Mix.shell().info([
        "\n#{inspect(repo)}\n\n",
        "  Status    Migration ID    Migration Name\n",
        String.duplicate("-", 50),
        "\n",
        rows
      ])
    end)
  end
end
