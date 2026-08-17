defmodule Dowser.Client.Codec.BuilderTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.Codec.BuilderFixtures.BaseCodec
  alias Dowser.Client.Codec.BuilderFixtures.ChildCodec
  alias Dowser.Client.Codec.BuilderFixtures.DateField
  alias Dowser.Client.Codec.BuilderFixtures.EchoCodec
  alias Dowser.Client.Codec.BuilderFixtures.IpField
  alias Dowser.Client.Codec.BuilderFixtures.NoFallbackNoNilCodec
  alias Dowser.Client.Codec.BuilderFixtures.OverlapChildCodec

  describe "cast/2 dispatch" do
    test "load/2 dispatches to the matching field module" do
      assert BaseCodec.load("2024-01-01", %{"type" => "date", "format" => "strict_date"}) ==
               ~D[2024-01-01]
    end

    test "dump/2 dispatches to the matching field module" do
      assert BaseCodec.dump(~D[2024-01-01], %{"type" => "date", "format" => "strict_date"}) ==
               "2024-01-01"
    end

    test "the whole matched field is passed through, not just the cast pattern" do
      field = %{"type" => "echo", "note" => "x"}
      assert EchoCodec.load("v", field) == {"v", field}
    end

    test "a value the field module can't parse passes through unchanged" do
      assert BaseCodec.load("not-a-date", %{"type" => "date", "format" => "strict_date"}) ==
               "not-a-date"
    end
  end

  describe "nil option (default true)" do
    test "load(nil, _) short-circuits to nil without reaching any field module" do
      assert BaseCodec.load(nil, %{"type" => "date", "format" => "strict_date"}) == nil
    end

    test "dump(nil, _) short-circuits to nil" do
      assert BaseCodec.dump(nil, %{"type" => "date", "format" => "strict_date"}) == nil
    end
  end

  describe "fallback option (default true)" do
    test "an unmatched field returns the value as-is" do
      assert BaseCodec.load("hello", %{"type" => "text"}) == "hello"
      assert BaseCodec.dump("hello", %{"type" => "text"}) == "hello"
    end
  end

  describe "fallback: false, nil: false" do
    test "raises FunctionClauseError for nil instead of returning nil" do
      assert_raise FunctionClauseError, fn ->
        NoFallbackNoNilCodec.load(nil, %{"type" => "text"})
      end
    end

    test "raises FunctionClauseError for an unmatched field instead of a fallback" do
      assert_raise FunctionClauseError, fn ->
        NoFallbackNoNilCodec.load("hello", %{"type" => "text"})
      end
    end

    test "a matched field still dispatches normally" do
      assert NoFallbackNoNilCodec.load("1.2.3.4", %{"type" => "ip"}) == {:ip, "1.2.3.4"}
    end
  end

  describe ":inherit" do
    test "a child codec dispatches values matched by the inherited codec" do
      assert ChildCodec.load("2024-01-01", %{"type" => "date", "format" => "strict_date"}) ==
               ~D[2024-01-01]
    end

    test "a child codec dispatches values matched by its own cast" do
      assert ChildCodec.load("1.2.3.4", %{"type" => "ip"}) == {:ip, "1.2.3.4"}
    end

    test "an inherited cast is tried before the child's own, so a broader inherited pattern shadows a narrower child pattern it overlaps with" do
      assert OverlapChildCodec.load("v", %{"type" => "date", "narrow" => true}) == {:a, "v"}
    end
  end

  describe "__casts__/0" do
    test "returns only the module's own casts, not inherited ones" do
      assert [{pattern, IpField}] = ChildCodec.__casts__()
      assert Macro.to_string(pattern) == ~s(%{"type" => "ip"})
    end

    test "an un-inherited codec's own casts include everything it declared" do
      assert [{pattern, DateField}] = BaseCodec.__casts__()
      assert Macro.to_string(pattern) == ~s(%{"type" => "date"})
    end
  end
end
