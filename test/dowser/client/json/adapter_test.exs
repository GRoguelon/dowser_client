defmodule Dowser.Client.JSON.AdapterTest do
  use ExUnit.Case, async: true

  # {adapter, backing module}. Full paths avoid aliasing `Jason`/`Poison`/`JSON`,
  # which would shadow the real modules we probe with Code.ensure_loaded?/1.
  @adapters [
    {Dowser.Client.JSON.Jason, Jason},
    {Dowser.Client.JSON.Poison, Poison},
    {Dowser.Client.JSON.Native, JSON}
  ]

  @term %{
    "query" => %{"match_all" => %{}},
    "size" => 10,
    "tags" => ["a", "b"],
    "nested" => %{"flag" => true, "score" => 1.5}
  }

  describe "available adapters" do
    for {adapter, backing} <- @adapters, Code.ensure_loaded?(backing) do
      test "#{inspect(adapter)} round-trips a term" do
        assert {:ok, iodata} = unquote(adapter).encode(@term, [])
        json = IO.iodata_to_binary(iodata)
        assert is_binary(json)
        assert {:ok, decoded} = unquote(adapter).decode(json, [])
        assert decoded == @term
      end

      test "#{inspect(adapter)} returns an error tuple on invalid JSON" do
        assert {:error, _reason} = unquote(adapter).decode(~s({"broken":), [])
      end
    end
  end

  describe "unavailable adapters" do
    for {adapter, backing} <- @adapters, not Code.ensure_loaded?(backing) do
      test "#{inspect(adapter)} raises a helpful error" do
        assert_raise RuntimeError, ~r/requires/, fn -> unquote(adapter).encode(@term, []) end
        assert_raise RuntimeError, ~r/requires/, fn -> unquote(adapter).decode("{}", []) end
      end
    end
  end
end
