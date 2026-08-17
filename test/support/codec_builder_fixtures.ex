defmodule Dowser.Client.CodecBuilderFixtures.DateField do
  @moduledoc false
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, %{"format" => "strict_date"}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> value
    end
  end

  @impl true
  def dump(%Date{} = date, %{"format" => "strict_date"}) do
    Date.to_iso8601(date)
  end

  def dump(value, _field), do: value
end

defmodule Dowser.Client.CodecBuilderFixtures.IpField do
  @moduledoc false
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, _field), do: {:ip, value}

  @impl true
  def dump({:ip, value}, _field), do: value
end

defmodule Dowser.Client.CodecBuilderFixtures.BaseCodec do
  @moduledoc false
  use Dowser.Client.CodecBuilder

  cast %{"type" => "date"}, Dowser.Client.CodecBuilderFixtures.DateField
end

defmodule Dowser.Client.CodecBuilderFixtures.ChildCodec do
  @moduledoc false
  use Dowser.Client.CodecBuilder, inherit: Dowser.Client.CodecBuilderFixtures.BaseCodec

  cast %{"type" => "ip"}, Dowser.Client.CodecBuilderFixtures.IpField
end

defmodule Dowser.Client.CodecBuilderFixtures.NoFallbackNoNilCodec do
  @moduledoc false
  use Dowser.Client.CodecBuilder, fallback: false, nil: false

  cast %{"type" => "ip"}, Dowser.Client.CodecBuilderFixtures.IpField
end

defmodule Dowser.Client.CodecBuilderFixtures.FieldA do
  @moduledoc false
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, _field), do: {:a, value}

  @impl true
  def dump({:a, value}, _field), do: value
end

defmodule Dowser.Client.CodecBuilderFixtures.FieldB do
  @moduledoc false
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, _field), do: {:b, value}

  @impl true
  def dump({:b, value}, _field), do: value
end

defmodule Dowser.Client.CodecBuilderFixtures.EchoField do
  @moduledoc false
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, field), do: {value, field}

  @impl true
  def dump(value, field), do: {value, field}
end

defmodule Dowser.Client.CodecBuilderFixtures.EchoCodec do
  @moduledoc false
  use Dowser.Client.CodecBuilder

  cast %{"type" => "echo"}, Dowser.Client.CodecBuilderFixtures.EchoField
end

defmodule Dowser.Client.CodecBuilderFixtures.OverlapParentCodec do
  @moduledoc false
  use Dowser.Client.CodecBuilder

  # Broader pattern than the child's — matches any "date" field, whatever
  # else is on it.
  cast %{"type" => "date"}, Dowser.Client.CodecBuilderFixtures.FieldA
end

defmodule Dowser.Client.CodecBuilderFixtures.OverlapChildCodec do
  @moduledoc false
  use Dowser.Client.CodecBuilder, inherit: Dowser.Client.CodecBuilderFixtures.OverlapParentCodec

  # Narrower than the inherited pattern above — matched values are a strict
  # subset of what the parent already matches, so the parent's clause (tried
  # first) always wins.
  cast %{"type" => "date", "narrow" => true}, Dowser.Client.CodecBuilderFixtures.FieldB
end
