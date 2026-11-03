defmodule Dowser.EnvelopeTest do
  use ExUnit.Case, async: true

  doctest Dowser.Envelope

  @mapping %{"properties" => %{"ip" => %{"type" => "ip"}}}

  test "each document is cast against its own index's mapping" do
    body = %{
      "docs" => [
        %{"_index" => "hosts", "_source" => %{"ip" => "127.0.0.1"}},
        %{"_index" => "other", "_source" => %{"ip" => "127.0.0.1"}}
      ]
    }

    mapping_fn = fn
      "hosts" ->
        @mapping

      _index ->
        nil
    end

    assert %{
             docs: [
               %{_source: %{ip: {127, 0, 0, 1}}},
               %{_source: %{ip: "127.0.0.1"}}
             ]
           } = Dowser.Envelope.load(body, mapping_fn, key_fn: &String.to_atom/1)
  end
end
