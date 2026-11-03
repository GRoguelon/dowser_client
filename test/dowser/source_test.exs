defmodule Dowser.SourceTest do
  use ExUnit.Case, async: true

  alias Dowser.Source

  doctest Dowser.Source

  @atoms [key_fn: &String.to_atom/1]

  @mapping %{
    "properties" => %{
      "ip" => %{"type" => "ip"},
      "period" => %{"type" => "date_range", "format" => "strict_date"},
      "where" => %{"type" => "geo_point"},
      "author" => %{
        "properties" => %{
          "name" => %{"type" => "keyword"},
          "born" => %{"type" => "date", "format" => "strict_date"}
        }
      },
      "comments" => %{
        "type" => "nested",
        "properties" => %{"at" => %{"type" => "date", "format" => "strict_date"}}
      },
      "roster" => %{"type" => "flat_object"},
      "stash" => %{"type" => "object", "enabled" => false}
    }
  }

  @opaque_types [opaque: ["flat_object"]]

  describe "load/3 — the mapping decides, not the value's shape" do
    test "an object is walked key by key against its properties" do
      source = %{"author" => %{"name" => "Ada", "born" => "1815-12-10"}}

      assert Source.load(source, @mapping, @atoms) == %{
               author: %{name: "Ada", born: ~D[1815-12-10]}
             }
    end

    test "a leaf gets its whole value, even when that value is a map" do
      source = %{
        "period" => %{"gte" => "2026-08-01", "lte" => "2026-08-11"},
        "where" => %{"lat" => 1.2, "lon" => 3.4}
      }

      assert Source.load(source, @mapping, @atoms) == %{
               period: Date.range(~D[2026-08-01], ~D[2026-08-11]),
               where: {1.2, 3.4}
             }
    end

    test "an object that merely looks like a range is still an object" do
      mapping = %{
        "properties" => %{
          "window" => %{
            "properties" => %{
              "gte" => %{"type" => "date", "format" => "strict_date"},
              "lte" => %{"type" => "date", "format" => "strict_date"}
            }
          }
        }
      }

      source = %{"window" => %{"gte" => "2026-08-01", "lte" => "2026-08-11"}}

      assert Source.load(source, mapping, @atoms) == %{
               window: %{gte: ~D[2026-08-01], lte: ~D[2026-08-11]}
             }
    end

    test "arrays are walked element by element, for objects and leaves alike" do
      source = %{
        "comments" => [%{"at" => "2026-08-01"}, %{"at" => "2026-08-02"}],
        "ip" => ["127.0.0.1", "10.0.0.1"]
      }

      assert Source.load(source, @mapping, @atoms) == %{
               comments: [%{at: ~D[2026-08-01]}, %{at: ~D[2026-08-02]}],
               ip: [{127, 0, 0, 1}, {10, 0, 0, 1}]
             }
    end

    test "a leaf map its type leaves uncast has its keys cast like the rest" do
      mapping = %{"properties" => %{"shape" => %{"type" => "geo_shape"}}}
      source = %{"shape" => %{"type" => "point", "coordinates" => [1, 2]}}

      assert Source.load(source, mapping, @atoms) == %{
               shape: %{type: "point", coordinates: [1, 2]}
             }
    end

    test "a field the mapping doesn't know keeps its value, its keys cast" do
      source = %{"extra" => %{"born" => "1815-12-10"}}

      assert Source.load(source, @mapping, @atoms) == %{extra: %{born: "1815-12-10"}}
    end

    test "nil stays nil, whatever the entry" do
      assert Source.load(%{"ip" => nil, "author" => nil}, @mapping) == %{
               "ip" => nil,
               "author" => nil
             }
    end

    test "no mapping at all only casts keys" do
      assert Source.load(%{"a" => %{"b" => 1}}, nil, @atoms) == %{a: %{b: 1}}
    end
  end

  describe "load/3 — opaque subtrees" do
    test "an opaque type is returned exactly as it arrived" do
      source = %{"roster" => %{"Managed Care Biller" => "Sam"}}

      assert Source.load(source, @mapping, @atoms ++ @opaque_types) == %{
               roster: %{"Managed Care Biller" => "Sam"}
             }
    end

    test "an object mapped enabled: false is opaque without being told" do
      source = %{"stash" => %{"born" => "1815-12-10"}}

      assert Source.load(source, @mapping, @atoms) == %{stash: %{"born" => "1815-12-10"}}
    end

    test "a type is only opaque when the backend says so" do
      source = %{"roster" => %{"division" => "WEST"}}

      assert Source.load(source, @mapping, @atoms) == %{roster: %{division: "WEST"}}
    end
  end

  describe "dump/3" do
    defmodule Author do
      defstruct [:name, :born]
    end

    test "leaves are dumped through their type, keys kept as given" do
      source = %{ip: {127, 0, 0, 1}, period: Date.range(~D[2026-08-01], ~D[2026-08-11])}

      assert Source.dump(source, @mapping) == %{
               ip: "127.0.0.1",
               period: %{"gte" => "2026-08-01", "lte" => "2026-08-11"}
             }
    end

    test "a struct under an object entry is dumped as a map" do
      source = %{"author" => %Author{name: "Ada", born: ~D[1815-12-10]}}

      assert Source.dump(source, @mapping) == %{
               "author" => %{name: "Ada", born: "1815-12-10"}
             }
    end

    test "a struct under a leaf entry is the type's to dump" do
      assert Source.dump(%{"period" => Date.range(~D[2026-08-01], ~D[2026-08-02])}, @mapping) ==
               %{"period" => %{"gte" => "2026-08-01", "lte" => "2026-08-02"}}
    end

    test "lists and MapSets are dumped element by element" do
      source = %{ip: MapSet.new([{127, 0, 0, 1}]), comments: [%{at: ~D[2026-08-01]}]}

      assert Source.dump(source, @mapping) == %{
               ip: MapSet.new(["127.0.0.1"]),
               comments: [%{at: "2026-08-01"}]
             }
    end

    test "an opaque subtree and an unknown field pass through untouched" do
      source = %{roster: %{when: ~D[2026-08-01]}, extra: %{when: ~D[2026-08-01]}}

      assert Source.dump(source, @mapping, @opaque_types) == source
    end
  end
end
