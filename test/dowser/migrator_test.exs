defmodule Dowser.MigratorTest.CreateEvents do
  use Dowser.Migration

  def change do
    create_index "events", body()
  end

  def body do
    %{
      settings: %{number_of_shards: 1, number_of_replicas: replicas()},
      mappings: %{
        dynamic: :strict,
        properties: %{
          client_id: %{type: :keyword},
          body: %{type: :text},
          legacy: %{type: :long},
          address: %{properties: %{city: %{type: :keyword}}},
          comments: %{type: :nested, properties: %{body: %{type: :text}, legacy: %{type: :long}}}
        }
      }
    }
  end

  defp replicas, do: if(is_pid(repo()), do: 0, else: 1)
end

defmodule Dowser.MigratorTest.CreateDashedEvents do
  use Dowser.Migration

  alias Dowser.MigratorTest.CreateEvents

  def change do
    create_index "events", CreateEvents.body(), separator: "-"
  end
end

defmodule Dowser.MigratorTest.DropEvents do
  use Dowser.Migration

  alias Dowser.MigratorTest.CreateEvents

  def change do
    drop_index "events", CreateEvents.body()
  end
end

defmodule Dowser.MigratorTest.AddStatus do
  use Dowser.Migration

  def change do
    alter_index "events" do
      add :status, %{type: :keyword}
      add [:address, :zip], %{type: :keyword}
      set :refresh_interval, "30s", from: nil
    end
  end
end

defmodule Dowser.MigratorTest.Reshape do
  use Dowser.Migration

  def change do
    alter_index "events" do
      rename :body, :content
      rename [:comments, :body], :content
      remove :legacy, %{type: :long}
      remove [:comments, :legacy], %{type: :long}
      add :kind, %{type: :keyword}, default: "event"
    end
  end
end

defmodule Dowser.MigratorTest.MoreReplicas do
  use Dowser.Migration

  def change do
    alter_index "events" do
      set :number_of_replicas, 2, from: 0
    end
  end
end

defmodule Dowser.MigratorTest.Shards do
  use Dowser.Migration

  def change do
    alter_index "events" do
      set :number_of_shards, 3, from: 1
    end
  end
end

defmodule Dowser.MigratorTest.CreateLogs do
  use Dowser.Migration

  def up do
    create_index "logs", %{mappings: %{properties: %{line: %{type: :text}}}}
  end

  def down do
    drop_index "logs"
  end
end

defmodule Dowser.MigratorTest.Irreversible do
  use Dowser.Migration

  def change do
    alter_index "events" do
      remove :legacy
    end
  end
end

defmodule Dowser.MigratorTest.WrongFrom do
  use Dowser.Migration

  def change do
    alter_index "events", from: 1 do
      add :status, %{type: :keyword}
    end
  end
end

defmodule Dowser.MigratorTest.Convert do
  use Dowser.Migration

  def change do
    alter_index "events" do
      modify :client_id, %{type: :long}, from: %{type: :keyword}

      script "ctx._source.client_id = Long.parseLong(ctx._source.client_id)",
        reverse: "ctx._source.client_id = String.valueOf(ctx._source.client_id)"
    end
  end
end

defmodule Dowser.MigratorTest do
  use ExUnit.Case, async: true

  alias Dowser.Migration.Error
  alias Dowser.Migration.IrreversibleError
  alias Dowser.Migrator
  alias Dowser.MigratorTest.AddStatus
  alias Dowser.MigratorTest.Convert
  alias Dowser.MigratorTest.CreateDashedEvents
  alias Dowser.MigratorTest.CreateEvents
  alias Dowser.MigratorTest.CreateLogs
  alias Dowser.MigratorTest.DropEvents
  alias Dowser.MigratorTest.Irreversible
  alias Dowser.MigratorTest.MoreReplicas
  alias Dowser.MigratorTest.Reshape
  alias Dowser.MigratorTest.Shards
  alias Dowser.MigratorTest.WrongFrom
  alias Dowser.Test.FakeCluster

  @v1 20_260_101_000_000
  @v2 20_260_102_000_000
  @v3 20_260_103_000_000
  @v4 20_260_104_000_000

  setup do
    %{cluster: FakeCluster.start()}
  end

  defp migrate(cluster, migrations, opts \\ []) do
    Migrator.run(cluster, :up, [adapter: FakeCluster, migrations: migrations, log: false] ++ opts)
  end

  defp rollback(cluster, migrations, opts \\ []) do
    Migrator.run(
      cluster,
      :down,
      [adapter: FakeCluster, migrations: migrations, log: false] ++ opts
    )
  end

  defp doc do
    %{
      "client_id" => "42",
      "body" => "hello",
      "legacy" => 1,
      "address" => %{"city" => "Paris"},
      "comments" => [%{"body" => "a", "legacy" => 2}, %{"body" => "b"}]
    }
  end

  describe "create_index" do
    test "creates the index behind the alias, versioned, and records the migration", %{
      cluster: cluster
    } do
      assert migrate(cluster, [{@v1, CreateEvents}]) == [@v1]

      index = FakeCluster.index(cluster, "events_#{@v1}")
      assert index["aliases"] == ["events"]
      assert index["mappings"]["_meta"] == %{"dowser_version" => @v1}
      assert index["mappings"]["dynamic"] == "strict"
      assert index["settings"]["number_of_replicas"] == 0

      assert [%{"version" => @v1, "indices" => ["events"], "dropped" => []}] =
               Map.values(FakeCluster.state(cluster).records)

      assert FakeCluster.state(cluster).lock == nil
    end

    test "runs nothing twice", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}])

      assert migrate(cluster, [{@v1, CreateEvents}]) == []
    end

    test "refuses an index that exists without the migrator", %{cluster: cluster} do
      :ok = FakeCluster.create_index(cluster, "events", %{})

      assert_raise Error, ~r/events is an index \(events\) the migrator didn't create/, fn ->
        migrate(cluster, [{@v1, CreateEvents}])
      end

      assert FakeCluster.state(cluster).lock == nil
    end
  end

  describe "live changes" do
    setup %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}])
      :ok
    end

    test "adds fields and dynamic settings in place", %{cluster: cluster} do
      assert migrate(cluster, [{@v1, CreateEvents}, {@v2, AddStatus}]) == [@v2]

      index = FakeCluster.index(cluster, "events_#{@v1}")
      assert index["aliases"] == ["events"]
      assert index["mappings"]["properties"]["status"] == %{"type" => "keyword"}

      assert index["mappings"]["properties"]["address"]["properties"]["zip"] == %{
               "type" => "keyword"
             }

      assert index["mappings"]["_meta"] == %{"dowser_version" => @v2}
      assert index["settings"]["refresh_interval"] == "30s"
      refute FakeCluster.index(cluster, "events_#{@v2}")
    end

    test "checks from: against the live setting", %{cluster: cluster} do
      :ok =
        FakeCluster.put_settings(cluster, "events_#{@v1}", %{"index.number_of_replicas" => "1"})

      assert_raise Error,
                   ~r/set index.number_of_replicas: it is "1", the migration expects 0/,
                   fn ->
                     migrate(cluster, [{@v1, CreateEvents}, {@v2, MoreReplicas}])
                   end
    end

    test "a static setting needs a copy", %{cluster: cluster} do
      assert_raise Error, ~r/set index.number_of_shards \(a static setting\).*--reindex/, fn ->
        migrate(cluster, [{@v1, CreateEvents}, {@v2, Shards}])
      end

      migrate(cluster, [{@v1, CreateEvents}, {@v2, Shards}], reindex: true)

      assert FakeCluster.index(cluster, "events_#{@v2}")["settings"]["number_of_shards"] == 3
    end

    test "checks alter_index's from: version", %{cluster: cluster} do
      assert_raise Error, ~r/alter_index from: 1, but the index is at version #{@v1}/, fn ->
        migrate(cluster, [{@v1, CreateEvents}, {@v2, WrongFrom}])
      end
    end
  end

  describe "copies" do
    setup %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}])
      :ok = FakeCluster.put_docs(cluster, "events", %{"1" => doc()})
      :ok
    end

    test "abort before any change without reindex: true", %{cluster: cluster} do
      before = FakeCluster.state(cluster).indices

      assert_raise Error,
                   ~r/rename body, rename comments.body, remove legacy.*run again with --reindex/,
                   fn ->
                     migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}])
                   end

      assert FakeCluster.state(cluster).indices == before
      assert FakeCluster.state(cluster).lock == nil
    end

    test "copy the documents through the field operations and move the alias", %{cluster: cluster} do
      assert migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}], reindex: true) == [@v2]

      old = FakeCluster.index(cluster, "events_#{@v1}")
      new = FakeCluster.index(cluster, "events_#{@v2}")

      assert old["aliases"] == []
      assert old["blocked"]
      assert new["aliases"] == ["events"]
      refute new["blocked"]
      assert new["mappings"]["_meta"] == %{"dowser_version" => @v2}

      assert FakeCluster.docs(cluster, "events") == %{
               "1" => %{
                 "client_id" => "42",
                 "content" => "hello",
                 "kind" => "event",
                 "address" => %{"city" => "Paris"},
                 "comments" => [%{"content" => "a"}, %{"content" => "b"}]
               }
             }
    end

    test "fold several migrations into one copy", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}, {@v2, AddStatus}, {@v3, Reshape}], reindex: true)

      assert FakeCluster.index(cluster, "events_#{@v3}")["aliases"] == ["events"]
      refute FakeCluster.index(cluster, "events_#{@v2}")

      assert [{:reindex, _, _}] =
               Enum.filter(FakeCluster.calls(cluster), &match?({:reindex, _, _}, &1))

      assert Enum.sort(Map.keys(FakeCluster.state(cluster).records)) == [@v1, @v2, @v3]
    end

    test "delete the previous index when asked", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}],
        reindex: true,
        delete_previous: true
      )

      refute FakeCluster.index(cluster, "events_#{@v1}")
    end

    test "skip the write block when asked", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}], reindex: true, write_block: false)

      refute FakeCluster.index(cluster, "events_#{@v1}")["blocked"]
    end

    test "run scripts between the field operations", %{cluster: cluster} do
      FakeCluster.scripts(cluster, %{
        "ctx._source.client_id = Long.parseLong(ctx._source.client_id)" => fn doc, _params ->
          Map.update!(doc, "client_id", &String.to_integer/1)
        end
      })

      migrate(cluster, [{@v1, CreateEvents}, {@v2, Convert}], reindex: true)

      assert %{"1" => %{"client_id" => 42}} = FakeCluster.docs(cluster, "events")
    end

    test "undo a failed copy: new index deleted, old one unblocked, lock released", %{
      cluster: cluster
    } do
      FakeCluster.fail(cluster, :reindex, :boom)

      assert_raise Error, ~r/copy events_#{@v1} into events_#{@v2} failed: :boom/, fn ->
        migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}], reindex: true)
      end

      refute FakeCluster.index(cluster, "events_#{@v2}")
      refute FakeCluster.index(cluster, "events_#{@v1}")["blocked"]
      assert FakeCluster.index(cluster, "events_#{@v1}")["aliases"] == ["events"]
      assert FakeCluster.state(cluster).lock == nil
      assert Map.keys(FakeCluster.state(cluster).records) == [@v1]
    end

    test "fail on document failures", %{cluster: cluster} do
      :ok = FakeCluster.put_docs(cluster, "events", %{"2" => Map.put(doc(), "content", "taken")})

      assert_raise Error, ~r/failed: \{:failures/, fn ->
        migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}], reindex: true)
      end

      refute FakeCluster.index(cluster, "events_#{@v2}")
    end

    test "keep the lock when the copy can't be undone, until recover/2", %{cluster: cluster} do
      FakeCluster.fail(cluster, :reindex, :boom)
      FakeCluster.fail(cluster, :remove_write_block, :down)

      assert_raise Error, ~r/undoing the copy failed too.*mix dowser.recover/, fn ->
        migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}], reindex: true)
      end

      assert %{"state" => %{"phase" => "copy", "index" => "events"}} =
               FakeCluster.state(cluster).lock

      assert_raise Error, ~r/stopped while copying events: run mix dowser.recover/, fn ->
        migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}], reindex: true)
      end

      FakeCluster.unfail(cluster, :remove_write_block)

      assert Migrator.recover(cluster, adapter: FakeCluster) == {:ok, {:undone, "events"}}
      refute FakeCluster.index(cluster, "events_#{@v2}")
      refute FakeCluster.index(cluster, "events_#{@v1}")["blocked"]
      assert FakeCluster.state(cluster).lock == nil

      FakeCluster.unfail(cluster, :reindex)
      assert migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}], reindex: true) == [@v2]
    end

    test "recover keeps a copy whose alias had moved", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}, {@v2, Reshape}], reindex: true)

      :ok =
        FakeCluster.lock(cluster, %{
          "owner" => "dead",
          "state" => %{
            "phase" => "copy",
            "index" => "events",
            "source" => "events_#{@v1}",
            "dest" => "events_#{@v2}",
            "blocked" => true
          }
        })

      assert Migrator.recover(cluster, adapter: FakeCluster) == {:ok, {:kept, "events"}}
      assert FakeCluster.index(cluster, "events_#{@v2}")["aliases"] == ["events"]
    end
  end

  describe "resuming" do
    test "an index already migrated but not recorded is skipped", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}])
      migrate(cluster, [{@v1, CreateEvents}, {@v2, AddStatus}])
      FakeCluster.unrecord(cluster, @v2)

      assert migrate(cluster, [{@v1, CreateEvents}, {@v2, AddStatus}]) == [@v2]
      assert Map.has_key?(FakeCluster.state(cluster).records, @v2)
    end

    test "an index changed outside of the migrations is refused", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}])

      :ok =
        FakeCluster.put_mapping(cluster, "events_#{@v1}", %{"_meta" => %{"dowser_version" => 1}})

      assert_raise Error,
                   ~r/events is at version 1, but the migrations expect it at version #{@v1}/,
                   fn ->
                     migrate(cluster, [{@v1, CreateEvents}, {@v2, AddStatus}])
                   end
    end
  end

  describe "rollback" do
    setup %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}])
      :ok = FakeCluster.put_docs(cluster, "events", %{"1" => doc()})
      :ok
    end

    test "reverts live changes in place", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}, {@v2, MoreReplicas}])

      assert rollback(cluster, [{@v1, CreateEvents}, {@v2, MoreReplicas}]) == [@v2]

      index = FakeCluster.index(cluster, "events_#{@v1}")
      assert index["settings"]["number_of_replicas"] == 0
      assert index["mappings"]["_meta"] == %{"dowser_version" => @v1}
      assert Map.keys(FakeCluster.state(cluster).records) == [@v1]
    end

    test "moves the alias back when the previous index still exists", %{cluster: cluster} do
      migrations = [{@v1, CreateEvents}, {@v2, Reshape}]
      migrate(cluster, migrations, reindex: true)

      assert rollback(cluster, migrations) == [@v2]

      old = FakeCluster.index(cluster, "events_#{@v1}")
      new = FakeCluster.index(cluster, "events_#{@v2}")
      assert old["aliases"] == ["events"]
      refute old["blocked"]
      assert new["aliases"] == []
      assert new["blocked"]
      assert FakeCluster.docs(cluster, "events") == %{"1" => doc()}
    end

    test "copies back, reverting the operations, when the previous index is gone", %{
      cluster: cluster
    } do
      migrations = [{@v1, CreateEvents}, {@v2, Reshape}]
      migrate(cluster, migrations, reindex: true, delete_previous: true)

      assert_raise Error, ~r/run again with --reindex/, fn -> rollback(cluster, migrations) end

      assert rollback(cluster, migrations, reindex: true) == [@v2]

      assert FakeCluster.index(cluster, "events_#{@v1}")["aliases"] == ["events"]

      assert FakeCluster.docs(cluster, "events") == %{
               "1" => %{
                 "client_id" => "42",
                 "body" => "hello",
                 "address" => %{"city" => "Paris"},
                 "comments" => [%{"body" => "a"}, %{"body" => "b"}]
               }
             }
    end

    test "rolls back an index created by the migration", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}, {@v4, CreateLogs}])

      assert rollback(cluster, [{@v1, CreateEvents}, {@v4, CreateLogs}]) == [@v4]
      refute FakeCluster.index(cluster, "logs_#{@v4}")

      assert rollback(cluster, [{@v1, CreateEvents}]) == [@v1]
      assert FakeCluster.state(cluster).indices == %{}
      assert FakeCluster.state(cluster).records == %{}
    end

    test "refuses an irreversible change before changing anything", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}, {@v2, Irreversible}], reindex: true)

      assert_raise IrreversibleError, ~r/remove legacy in "events" without its definition/, fn ->
        rollback(cluster, [{@v1, CreateEvents}, {@v2, Irreversible}])
      end

      assert FakeCluster.state(cluster).lock == nil
    end
  end

  describe "separators" do
    test "an index created with a separator keeps it through copies and rollbacks", %{
      cluster: cluster
    } do
      migrations = [{@v1, CreateDashedEvents}, {@v2, Reshape}]
      migrate(cluster, [{@v1, CreateDashedEvents}])
      :ok = FakeCluster.put_docs(cluster, "events", %{"1" => doc()})

      assert FakeCluster.index(cluster, "events-#{@v1}")["aliases"] == ["events"]
      assert %{"separators" => %{"events" => "-"}} = FakeCluster.state(cluster).records[@v1]

      migrate(cluster, migrations, reindex: true)

      assert FakeCluster.index(cluster, "events-#{@v2}")["aliases"] == ["events"]
      assert FakeCluster.index(cluster, "events-#{@v1}")["blocked"]

      rollback(cluster, migrations)

      assert FakeCluster.index(cluster, "events-#{@v1}")["aliases"] == ["events"]
      assert FakeCluster.docs(cluster, "events") == %{"1" => doc()}
    end

    test "a rollback copying back names the index with it", %{cluster: cluster} do
      migrations = [{@v1, CreateDashedEvents}, {@v2, Reshape}]
      migrate(cluster, [{@v1, CreateDashedEvents}])
      migrate(cluster, migrations, reindex: true, delete_previous: true)

      rollback(cluster, migrations, reindex: true)

      assert FakeCluster.index(cluster, "events-#{@v1}")["aliases"] == ["events"]
      refute FakeCluster.index(cluster, "events_#{@v1}")
    end

    test "an index a rollback recreates gets the separator of the one dropped", %{
      cluster: cluster
    } do
      migrations = [{@v1, CreateDashedEvents}, {@v2, DropEvents}]
      migrate(cluster, migrations)

      assert FakeCluster.state(cluster).indices == %{}

      assert rollback(cluster, migrations) == [@v2]
      assert FakeCluster.index(cluster, "events-#{@v1}")["aliases"] == ["events"]
    end

    test "siblings named with another separator aren't the index's copies", %{cluster: cluster} do
      migrations = [{@v1, CreateDashedEvents}, {@v2, Reshape}]
      migrate(cluster, [{@v1, CreateDashedEvents}])
      migrate(cluster, migrations, reindex: true, delete_previous: true)

      # Same version, other separator: not the index's previous copy.
      :ok =
        FakeCluster.create_index(cluster, "events_#{@v1}", %{
          "mappings" => %{"_meta" => %{"dowser_version" => @v1}}
        })

      assert_raise Error, ~r/run again with --reindex/, fn -> rollback(cluster, migrations) end
    end
  end

  describe "plan/3 and migrations/2" do
    test "describe the requests without sending any", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}])

      plan =
        Migrator.plan(cluster, :up,
          adapter: FakeCluster,
          migrations: [{@v1, CreateEvents}, {@v2, Reshape}],
          reindex: true
        )

      text = Migrator.format_plan(plan)

      assert text =~ "Migrate #{@v2} (reshape)"
      assert text =~ "PUT /events_#{@v1}/_block/write"
      assert text =~ "POST /_reindex?wait_for_completion=false"
      assert text =~ ~s("dowser_ops_0":[{"from":"body")
      assert text =~ ~s(POST /_aliases)
      refute FakeCluster.index(cluster, "events_#{@v2}")
    end

    test "list the migrations and whether they ran", %{cluster: cluster} do
      migrate(cluster, [{@v1, CreateEvents}])
      migrations = [{@v1, CreateEvents}, {@v2, AddStatus}]

      assert Migrator.migrations(cluster, adapter: FakeCluster, migrations: migrations) == [
               {:up, @v1, "create_events"},
               {:down, @v2, "add_status"}
             ]
    end
  end

  describe "files" do
    @tag :tmp_dir
    test "loads migrations from a directory", %{cluster: cluster, tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "#{@v1}_create_things.exs"), """
      defmodule Dowser.MigratorTest.Files.CreateThings do
        use Dowser.Migration

        def change do
          create_index "things", %{mappings: %{properties: %{name: %{type: :keyword}}}}
        end
      end
      """)

      assert Migrator.run(cluster, :up,
               adapter: FakeCluster,
               migrations_path: tmp_dir,
               log: false
             ) == [@v1]

      assert Migrator.migrations(cluster, adapter: FakeCluster, migrations_path: tmp_dir) == [
               {:up, @v1, "create_things"}
             ]
    end
  end
end
