defmodule Mix.Tasks.Dowser.Migrate do
  @shortdoc "Runs the pending Dowser migrations"

  @moduledoc """
  Runs the pending migrations of a repo; see `Dowser.Migrator`.

      $ mix dowser.migrate
      $ mix dowser.migrate -r MyApp.Search --reindex
      $ mix dowser.migrate --dry-run --reindex

  The repos are given with `-r`, or configured as the project's
  `:dowser_repos`:

      config :my_app, dowser_repos: [MyApp.Search]

  ## Options

    * `-r`, `--repo` — the repo to migrate (repeatable).
    * `--all` — every pending migration (the default).
    * `-n`, `--step` — the next `n` pending migrations.
    * `--to` — the pending migrations up to and including this version.
    * `--reindex` — allow copying an index into a new one, for the changes
      the engine can't make in place. Without it, such a migration aborts the
      run before anything changes.
    * `--no-write-block` — don't block writes to an index while it is copied.
    * `--delete-previous` — delete the index a copy replaced.
    * `--dry-run` — print the requests the run would send, and send none.
    * `--migrations-path` — where the migrations are (default: the repo's
      `:migrations_path`, or `priv/dowser/migrations`).
    * `--quiet` — log nothing.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args), do: Mix.Dowser.run(:up, args)
end
