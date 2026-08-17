defmodule Dowser.BlankTest do
  use ExUnit.Case, async: true

  alias Dowser.Blank

  describe "blank?/1" do
    test "nil atom is blank" do
      assert Blank.blank?(nil)
    end

    test "a non-nil atom is not blank" do
      refute Blank.blank?(:ok)
    end

    test "an empty or whitespace-only string is blank" do
      assert Blank.blank?("")
      assert Blank.blank?("   ")
      assert Blank.blank?("\n\t")
    end

    test "a non-blank string is not blank" do
      refute Blank.blank?("x")
      refute Blank.blank?(" x ")
    end

    test "an empty map, list and MapSet are blank" do
      assert Blank.blank?(%{})
      assert Blank.blank?([])
      assert Blank.blank?(MapSet.new())
    end

    test "a non-empty map, list and MapSet are not blank" do
      refute Blank.blank?(%{a: 1})
      refute Blank.blank?([1])
      refute Blank.blank?(MapSet.new([1]))
    end

    test "any other term (numbers, booleans, structs) falls back to false" do
      refute Blank.blank?(0)
      refute Blank.blank?(false)
      refute Blank.blank?(~D[2024-01-01])
    end
  end

  describe "present?/1" do
    test "is the exact opposite of blank?/1" do
      assert Blank.present?("x")
      refute Blank.present?("")
      refute Blank.present?(nil)
    end
  end

  describe "presence/1" do
    test "returns the value when present" do
      assert Blank.presence("x") == "x"
      assert Blank.presence(%{a: 1}) == %{a: 1}
    end

    test "returns nil when blank" do
      assert Blank.presence("") == nil
      assert Blank.presence(nil) == nil
      assert Blank.presence([]) == nil
    end
  end
end
