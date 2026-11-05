defmodule Dowser.MigrationTest do
  use ExUnit.Case, async: true

  import Dowser.Migration

  alias Dowser.Migration
  alias Dowser.Migration.Command
  alias Dowser.Migration.IrreversibleError
  alias Dowser.Migration.Script
  alias Dowser.Migration.Settings
  alias Dowser.Test.FakeCluster

  defp record(fun), do: Migration.__record__(:repo, fun)

  describe "recording" do
    test "normalizes names, paths and bodies" do
      commands =
        record(fn ->
          create_index :events, %{
            settings: %{index: %{number_of_shards: 1}},
            mappings: %{dynamic: :strict}
          }

          alter_index "events", from: 1 do
            add [:address, :zip], %{type: :keyword}, default: "none"
            modify :group_id, %{type: :keyword}, from: %{type: :keyword, ignore_above: 256}
            rename :body, :content
            remove :legacy, %{type: :long}
            set [:index, :analysis, :analyzer, :folded], %{tokenizer: :standard}, from: nil
            set "index.number_of_replicas", 2
            unset :max_result_window, from: 50_000

            script "ctx._source.x = params.x",
              params: %{x: 1},
              reverse: "ctx._source.remove('x')"
          end

          drop_index "events"
        end)

      assert commands == [
               {:create_index, "events",
                %{
                  "settings" => %{"index" => %{"number_of_shards" => 1}},
                  "mappings" => %{"dynamic" => "strict"}
                }, []},
               {:alter_index, "events", 1,
                [
                  {:add, ["address", "zip"], %{"type" => "keyword"}, {:ok, "none"}},
                  {:modify, ["group_id"], %{"type" => "keyword"},
                   {:ok, %{"type" => "keyword", "ignore_above" => 256}}},
                  {:rename, ["body"], "content"},
                  {:remove, ["legacy"], %{"type" => "long"}},
                  {:set, ["analysis", "analyzer", "folded"], %{"tokenizer" => "standard"},
                   {:ok, nil}},
                  {:set, ["number_of_replicas"], 2, :error},
                  {:unset, ["max_result_window"], {:ok, 50_000}},
                  {:script, "ctx._source.x = params.x", %{"x" => 1},
                   {:ok, "ctx._source.remove('x')"}}
                ]},
               {:drop_index, "events", nil}
             ]
    end

    test "takes the separator of the index's name" do
      assert record(fn -> create_index "events", %{}, separator: "-" end) ==
               [{:create_index, "events", %{}, [separator: "-"]}]

      for separator <- ["", "1", "A", "*", "a b", "#", :dash] do
        assert_raise ArgumentError, ~r/separator/, fn ->
          record(fn -> create_index "events", %{}, separator: separator end)
        end
      end
    end

    test "gives the repo being migrated" do
      assert record(fn -> send(self(), {:repo, repo()}) end) == []
      assert_received {:repo, :repo}

      assert_raise ArgumentError, ~r/only available while a migration runs/, fn -> repo() end
    end

    test "rejects operations out of place" do
      assert_raise ArgumentError, ~r/only available inside alter_index/, fn ->
        record(fn -> add(:x, %{type: :keyword}) end)
      end

      assert_raise ArgumentError, ~r/create_index can't be used inside alter_index/, fn ->
        record(fn ->
          alter_index "events" do
            create_index "other", %{}
          end
        end)
      end

      assert_raise ArgumentError, ~r/only available while a migration runs/, fn ->
        create_index "events", %{}
      end

      assert_raise ArgumentError, ~r/:from is a migration version/, fn ->
        record(fn ->
          alter_index "events", from: "x" do
            add :x, %{type: :keyword}
          end
        end)
      end
    end
  end

  describe "inverting" do
    test "inverts each command, in reverse order" do
      commands =
        record(fn ->
          create_index "events", %{mappings: %{}}

          alter_index "events" do
            add :status, %{type: :keyword}
            rename [:comments, :body], :content
            set :number_of_replicas, 2, from: 1
            set :refresh_interval, "30s", from: nil
            unset :max_result_window, from: 50_000
          end
        end)

      assert Command.invert(commands) == [
               {:alter_index, "events", nil,
                [
                  {:set, ["max_result_window"], 50_000, {:ok, nil}},
                  {:unset, ["refresh_interval"], {:ok, "30s"}},
                  {:set, ["number_of_replicas"], 1, {:ok, 2}},
                  {:rename, ["comments", "content"], "body"},
                  {:remove, ["status"], %{"type" => "keyword"}}
                ]},
               {:drop_index, "events", %{"mappings" => %{}}}
             ]
    end

    test "refuses what can't be inverted" do
      for {op, message} <- [
            {fn -> remove(:legacy) end, ~r/remove legacy in "events" without its definition/},
            {fn -> modify(:x, %{type: :long}) end, ~r/modify x in "events" without from:/},
            {fn -> set(:number_of_replicas, 2) end,
             ~r/set index.number_of_replicas in "events" without from:/},
            {fn -> unset(:refresh_interval) end,
             ~r/unset index.refresh_interval in "events" without from:/},
            {fn -> script("x") end, ~r/a script in "events" without reverse:/}
          ] do
        commands =
          record(fn ->
            alter_index "events" do
              op.()
            end
          end)

        assert_raise IrreversibleError, message, fn -> Command.invert(commands) end
      end

      assert_raise IrreversibleError, ~r/drop_index "events" without the index's body/, fn ->
        Command.invert(record(fn -> drop_index("events") end))
      end
    end
  end

  describe "the reindex script" do
    test "is the routine and one call per run of field operations, the names as params" do
      script =
        Script.build([
          {:rename, ["comments", "body"], "content"},
          {:remove, ["legacy"]},
          {:script, "ctx._source.x = params.x;", %{"x" => 1}},
          {:add, ["kind"], "event"}
        ])

      assert script["lang"] == "painless"

      assert script["source"] ==
               String.trim_trailing(Script.routine()) <>
                 "\ndowserApply(ctx._source, params.dowser_ops_0);" <>
                 "\nctx._source.x = params.x;" <>
                 "\ndowserApply(ctx._source, params.dowser_ops_2);"

      assert script["params"] == %{
               "x" => 1,
               "dowser_ops_0" => [
                 %{"op" => "rename", "path" => ["comments"], "from" => "body", "to" => "content"},
                 %{"op" => "remove", "path" => [], "field" => "legacy"}
               ],
               "dowser_ops_2" => [
                 %{"op" => "add", "path" => [], "field" => "kind", "value" => "event"}
               ]
             }
    end

    test "has the same source whatever the fields" do
      source = fn ops -> Script.build(ops)["source"] end

      assert source.([{:remove, ["a"]}]) == source.([{:rename, ["b", "c"], "d'); evil('"}])
      assert Script.build([]) == nil
    end

    test "refuses two scripts giving one parameter different values" do
      assert_raise Dowser.Migration.Error, ~r/parameter "x"/, fn ->
        Script.build([{:script, "a", %{"x" => 1}}, {:script, "b", %{"x" => 2}}])
      end
    end
  end

  # The semantics the painless routine implements, through its Elixir mirror.
  describe "the routine's semantics" do
    defp apply_ops(doc, ops) do
      %{"params" => %{"dowser_ops_0" => ops}} = Script.build(ops)
      FakeCluster.apply_ops(doc, ops)
    end

    test "changes a field in every object of a list, lists of lists included" do
      doc = %{"comments" => [%{"body" => 1}, [%{"body" => 2}, [%{"body" => 3}]], nil, "text", 4]}

      assert apply_ops(doc, [{:rename, ["comments", "body"], "content"}]) ==
               {:ok,
                %{
                  "comments" => [
                    %{"content" => 1},
                    [%{"content" => 2}, [%{"content" => 3}]],
                    nil,
                    "text",
                    4
                  ]
                }}
    end

    test "skips missing, null and scalar parents" do
      for doc <- [%{}, %{"address" => nil}, %{"address" => "Paris"}, %{"address" => [1, 2]}] do
        assert apply_ops(doc, [{:remove, ["address", "zip"]}]) == {:ok, doc}
      end
    end

    test "finds fields stored with dotted names" do
      doc = %{"address.zip" => "75001", "a" => %{"b.c" => %{"d" => 1}}, "a.b" => %{"c.d" => 2}}

      assert apply_ops(doc, [
               {:rename, ["address", "zip"], "postcode"},
               {:remove, ["a", "b", "c", "d"]}
             ]) ==
               {:ok, %{"address.postcode" => "75001", "a" => %{"b.c" => %{}}, "a.b" => %{}}}
    end

    test "fails a rename onto an existing field rather than lose a value" do
      assert {:error, message} =
               apply_ops(%{"body" => 1, "content" => 2}, [{:rename, ["body"], "content"}])

      assert message =~ "cannot rename [body] to [content]"
    end

    test "adds a default only to existing objects missing the field" do
      doc = %{"address" => [%{"city" => "Paris"}, %{"city" => "Lyon", "zip" => "69001"}]}

      assert apply_ops(doc, [{:add, ["address", "zip"], "none"}]) ==
               {:ok,
                %{
                  "address" => [
                    %{"city" => "Paris", "zip" => "none"},
                    %{"city" => "Lyon", "zip" => "69001"}
                  ]
                }}

      assert apply_ops(%{}, [{:add, ["address", "zip"], "none"}]) == {:ok, %{}}

      assert apply_ops(%{}, [{:add, ["kind"], %{"a" => [1]}}]) ==
               {:ok, %{"kind" => %{"a" => [1]}}}
    end
  end

  describe "settings" do
    test "flattens any shape, relative to index" do
      assert Settings.flatten(%{
               "index" => %{
                 "number_of_shards" => 1,
                 "analysis" => %{"analyzer" => %{"a" => %{"filter" => ["x"]}}}
               },
               "index.refresh_interval" => "1s",
               "max_result_window" => 10
             }) == %{
               "number_of_shards" => 1,
               "analysis.analyzer.a.filter" => ["x"],
               "refresh_interval" => "1s",
               "max_result_window" => 10
             }
    end

    test "compares as the engine stores them" do
      assert Settings.same?(%{"a" => "1", "b" => ["x"]}, %{"a" => 1, "b" => [:x]})
      refute Settings.same?(%{"a" => "1"}, %{"a" => 2})
    end

    test "diffs into an update body" do
      assert Settings.diff(%{"a" => "1", "b" => "2", "c" => "3"}, %{
               "a" => 1,
               "b" => "5",
               "d" => "4"
             }) ==
               %{"index.b" => "5", "index.c" => nil, "index.d" => "4"}
    end

    test "knows the dynamic settings" do
      assert Settings.dynamic?("number_of_replicas")
      assert Settings.dynamic?("routing.allocation.require.box")
      refute Settings.dynamic?("number_of_shards")
      refute Settings.dynamic?("analysis.analyzer.folded.tokenizer")
    end
  end
end
