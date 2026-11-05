defmodule Mix.Tasks.Dowser.Rollback do
  @shortdoc "Rolls back the last Dowser migration"

  @moduledoc """
  Reverts the last migrations a repo ran; see "Rolling back" in
  `Dowser.Migrator`.

      $ mix dowser.rollback
      $ mix dowser.rollback -n 3
      $ mix dowser.rollback --to 20261104120000 --reindex

  An index whose previous version still exists moves back onto it, without
  copying anything — the documents written since the migration aren't in it.
  Otherwise, an index the migrations changed in a way the engine can't revert
  in place is copied again, with `--reindex`.

  ## Options

    * `-r`, `--repo` — the repo to roll back (repeatable).
    * `-n`, `--step` — the last `n` migrations (default `1`).
    * `--to` — down to and including this version.
    * `--all` — every migration run.
    * `--reindex`, `--no-write-block`, `--delete-previous`, `--dry-run`,
      `--migrations-path`, `--quiet` — as for `mix dowser.migrate`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args), do: Mix.Dowser.run(:down, args)
end
