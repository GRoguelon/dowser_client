defmodule Mix.Dowser do
  @moduledoc false

  # What the `dowser.*` Mix tasks share: which repos they act on, where their
  # migrations are in the project, and starting what they need.

  @default_path "priv/dowser/migrations"

  @doc """
  The repos given with `-r`/`--repo`, or the project's `:dowser_repos`
  (`config :my_app, dowser_repos: [MyApp.Search]`).
  """
  @spec repos([String.t()]) :: [module()]
  def repos(args) do
    {opts, _rest, _other} = OptionParser.parse(args, strict: [repo: :keep], aliases: [r: :repo])

    case Keyword.get_values(opts, :repo) do
      [] ->
        app = Mix.Project.config()[:app]

        case Application.get_env(app, :dowser_repos, []) do
          [] ->
            Mix.raise(
              "no repo to migrate: pass -r MyApp.Search, or configure " <>
                "`config #{inspect(app)}, dowser_repos: [MyApp.Search]`"
            )

          repos ->
            repos
        end

      repos ->
        Enum.map(repos, &Module.concat([&1]))
    end
  end

  @doc "Removes `-r`/`--repo` from `args`."
  @spec drop_repo_args([String.t()]) :: [String.t()]
  def drop_repo_args([flag, _repo | rest]) when flag in ["-r", "--repo"], do: drop_repo_args(rest)
  def drop_repo_args(["--repo=" <> _repo | rest]), do: drop_repo_args(rest)
  def drop_repo_args([arg | rest]), do: [arg | drop_repo_args(rest)]
  def drop_repo_args([]), do: []

  @doc """
  `repo`'s migrations directory in the project: its `:migrations_path`, or
  `priv/dowser/migrations`, from the project's root.
  """
  @spec migrations_path(module()) :: String.t()
  def migrations_path(repo) do
    ensure_repo!(repo)

    path =
      repo.__otp_app__()
      |> Application.get_env(repo, [])
      |> Keyword.get(:migrations_path, @default_path)

    Path.expand(path, File.cwd!())
  end

  @doc "Compiles and configures the project, and starts `dowser_client`."
  @spec start!() :: :ok
  def start! do
    Mix.Task.run("app.config")

    case Application.ensure_all_started(:dowser_client) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        Mix.raise("could not start dowser_client: #{inspect(reason)}")
    end
  end

  @doc "Raises unless `repo` is a repo module."
  @spec ensure_repo!(module()) :: :ok
  def ensure_repo!(repo) do
    if Dowser.Repo.repo?(repo) do
      :ok
    else
      Mix.raise(
        "#{inspect(repo)} is not a repo: define it with `use Dowser.OpenSearch.Repo` (or Elasticsearch)"
      )
    end
  end

  @doc "The switches `dowser.migrate` and `dowser.rollback` share, as `Dowser.Migrator.run/3` options."
  @spec run_opts([String.t()]) :: {keyword(), boolean()}
  def run_opts(args) do
    {opts, _rest} =
      OptionParser.parse!(drop_repo_args(args),
        strict: [
          all: :boolean,
          step: :integer,
          to: :integer,
          reindex: :boolean,
          delete_previous: :boolean,
          write_block: :boolean,
          dry_run: :boolean,
          quiet: :boolean,
          migrations_path: :string
        ],
        aliases: [n: :step]
      )

    {dry_run, opts} = Keyword.pop(opts, :dry_run, false)
    {quiet, opts} = Keyword.pop(opts, :quiet, false)

    opts = if quiet, do: Keyword.put(opts, :log, false), else: opts

    {opts, dry_run}
  end

  @doc "Runs `dowser.migrate` or `dowser.rollback`."
  @spec run(:up | :down, [String.t()]) :: :ok
  def run(direction, args) do
    {opts, dry_run} = run_opts(args)
    start!()
    repos = repos(args)

    Enum.each(repos, fn repo ->
      ensure_repo!(repo)
      opts = Keyword.put_new_lazy(opts, :migrations_path, fn -> migrations_path(repo) end)

      if dry_run do
        plan = Dowser.Migrator.plan(repo, direction, opts)
        Mix.shell().info("#{inspect(repo)}:\n" <> Dowser.Migrator.format_plan(plan))
      else
        repo |> Dowser.Migrator.run(direction, opts) |> report(repo, direction)
      end
    end)
  end

  defp report([], repo, :up), do: Mix.shell().info("#{inspect(repo)}: nothing to migrate")
  defp report([], repo, :down), do: Mix.shell().info("#{inspect(repo)}: nothing to roll back")

  defp report(versions, repo, direction) do
    verb = if direction == :up, do: "migrated", else: "rolled back"

    Mix.shell().info("#{inspect(repo)}: #{verb} #{Enum.join(versions, ", ")}")
  end
end
