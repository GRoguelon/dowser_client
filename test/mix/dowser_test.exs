defmodule Mix.DowserTest do
  use ExUnit.Case, async: true

  describe "drop_repo_args/1" do
    test "removes every repo switch, and keeps the others" do
      assert Mix.Dowser.drop_repo_args([
               "-r",
               "A",
               "--reindex",
               "--repo",
               "B",
               "--repo=C",
               "-n",
               "2"
             ]) ==
               ["--reindex", "-n", "2"]
    end
  end

  describe "repos/1" do
    test "takes the repos given" do
      assert Mix.Dowser.repos(["-r", "MyApp.Search", "--reindex", "--repo", "MyApp.Logs"]) ==
               [MyApp.Search, MyApp.Logs]
    end
  end

  describe "run_opts/1" do
    test "turns the switches into Dowser.Migrator.run/3 options" do
      assert {opts, false} =
               Mix.Dowser.run_opts([
                 "-r",
                 "MyApp.Search",
                 "--reindex",
                 "--no-write-block",
                 "--delete-previous",
                 "-n",
                 "2",
                 "--quiet"
               ])

      assert Enum.sort(opts) ==
               Enum.sort(
                 reindex: true,
                 write_block: false,
                 delete_previous: true,
                 step: 2,
                 log: false
               )

      assert Mix.Dowser.run_opts(["--dry-run", "--to", "20261104120000"]) ==
               {[to: 20_261_104_120_000], true}
    end
  end
end

defmodule Mix.Tasks.Dowser.Gen.MigrationTest do
  use ExUnit.Case

  alias Mix.Tasks.Dowser.Gen.Migration, as: GenMigration

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "writes a timestamped migration named after the repo", %{tmp_dir: tmp_dir} do
    GenMigration.run([
      "add_status_to_events",
      "-r",
      "Dowser.TestRepo",
      "--migrations-path",
      tmp_dir
    ])

    assert [file] = Path.wildcard(Path.join(tmp_dir, "*_add_status_to_events.exs"))
    assert Path.basename(file) =~ ~r/\A\d{14}_add_status_to_events\.exs\z/

    assert File.read!(file) == """
           defmodule Dowser.TestRepo.Migrations.AddStatusToEvents do
             use Dowser.Migration

             def change do
             end
           end
           """

    assert_raise Mix.Error, ~r/already exists/, fn ->
      GenMigration.run([
        "add_status_to_events",
        "-r",
        "Dowser.TestRepo",
        "--migrations-path",
        tmp_dir
      ])
    end
  end

  test "refuses a name that isn't snake_case" do
    assert_raise Mix.Error, ~r/snake_case/, fn ->
      GenMigration.run(["AddStatus", "-r", "Dowser.TestRepo"])
    end
  end
end
