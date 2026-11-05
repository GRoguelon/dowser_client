defmodule Mix.Tasks.Dowser.Recover do
  @shortdoc "Undoes what a stopped Dowser migration run left behind"

  @moduledoc """
  Undoes what a migration run left behind when it stopped in the middle of
  copying an index — the node died, or undoing a failed copy failed too — and
  releases the migration lock; see `Dowser.Migrator.recover/2`.

      $ mix dowser.recover -r MyApp.Search

  Run it only when no migration is running: it releases the lock whoever
  holds it.

  ## Options

    * `-r`, `--repo` — the repo (repeatable).
  """

  use Mix.Task

  alias Dowser.Migration.Runner

  @impl Mix.Task
  def run(args) do
    Mix.Dowser.start!()
    repos = Mix.Dowser.repos(args)

    Enum.each(repos, fn repo ->
      Mix.Dowser.ensure_repo!(repo)

      case Dowser.Migrator.recover(repo) do
        {:ok, :unlocked} ->
          Mix.shell().info("#{inspect(repo)}: no lock, nothing to recover")

        {:ok, :released} ->
          Mix.shell().info("#{inspect(repo)}: lock released")

        {:ok, {:undone, index}} ->
          Mix.shell().info(
            "#{inspect(repo)}: the copy of #{index} was undone — its index unblocked, the new one deleted — and the lock released"
          )

        {:ok, {:kept, index}} ->
          Mix.shell().info(
            "#{inspect(repo)}: #{index} had moved onto its copy, which is kept; lock released. " <>
              "Run mix dowser.migrate to record the migrations"
          )

        {:error, reason} ->
          Mix.raise("#{inspect(repo)}: recovering failed: #{Runner.format(reason)}")
      end
    end)
  end
end
