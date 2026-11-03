defmodule Dowser.Type.IP do
  @moduledoc "`ip` — a string <-> an `:inet` address tuple (`{1, 2, 3, 4}`)."

  require Logger

  @behaviour Dowser.Type

  @impl true
  def load(value, _field) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, address} ->
        address

      {:error, error} ->
        Logger.error("Unknown error while loading Dowser.Type.IP: #{error}")

        value
    end
  end

  def load(value, _field) do
    value
  end

  @impl true
  def dump(address, _field) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, error} ->
        Logger.error("Unknown error while dumping Dowser.Type.IP: #{error}")

        address

      charlist ->
        to_string(charlist)
    end
  end

  def dump(value, _field) do
    value
  end
end
