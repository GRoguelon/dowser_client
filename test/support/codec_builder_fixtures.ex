defmodule Dowser.Client.Codec.BuilderFixtures.DateField do
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

defmodule Dowser.Client.Codec.BuilderFixtures.IpField do
  @moduledoc false
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, _field), do: {:ip, value}

  @impl true
  def dump({:ip, value}, _field), do: value
end

defmodule Dowser.Client.Codec.BuilderFixtures.BaseCodec do
  @moduledoc false
  use Dowser.Client.Codec.Builder

  cast %{"type" => "date"}, Dowser.Client.Codec.BuilderFixtures.DateField
end

defmodule Dowser.Client.Codec.BuilderFixtures.ChildCodec do
  @moduledoc false
  use Dowser.Client.Codec.Builder, inherit: Dowser.Client.Codec.BuilderFixtures.BaseCodec

  cast %{"type" => "ip"}, Dowser.Client.Codec.BuilderFixtures.IpField
end

defmodule Dowser.Client.Codec.BuilderFixtures.NoFallbackNoNilCodec do
  @moduledoc false
  use Dowser.Client.Codec.Builder, fallback: false, nil: false

  cast %{"type" => "ip"}, Dowser.Client.Codec.BuilderFixtures.IpField
end

defmodule Dowser.Client.Codec.BuilderFixtures.FieldA do
  @moduledoc false
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, _field), do: {:a, value}

  @impl true
  def dump({:a, value}, _field), do: value
end

defmodule Dowser.Client.Codec.BuilderFixtures.FieldB do
  @moduledoc false
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, _field), do: {:b, value}

  @impl true
  def dump({:b, value}, _field), do: value
end

defmodule Dowser.Client.Codec.BuilderFixtures.EchoField do
  @moduledoc false
  @behaviour Dowser.Client.Field

  @impl true
  def load(value, field), do: {value, field}

  @impl true
  def dump(value, field), do: {value, field}
end

defmodule Dowser.Client.Codec.BuilderFixtures.EchoCodec do
  @moduledoc false
  use Dowser.Client.Codec.Builder

  cast %{"type" => "echo"}, Dowser.Client.Codec.BuilderFixtures.EchoField
end

defmodule Dowser.Client.Codec.BuilderFixtures.OverlapParentCodec do
  @moduledoc false
  use Dowser.Client.Codec.Builder

  # Broader pattern than the child's — matches any "date" field, whatever
  # else is on it.
  cast %{"type" => "date"}, Dowser.Client.Codec.BuilderFixtures.FieldA
end

defmodule Dowser.Client.Codec.BuilderFixtures.OverlapChildCodec do
  @moduledoc false
  use Dowser.Client.Codec.Builder,
    inherit: Dowser.Client.Codec.BuilderFixtures.OverlapParentCodec

  # Narrower than the inherited pattern above — matched values are a strict
  # subset of what the parent already matches, so the parent's clause (tried
  # first) always wins.
  cast %{"type" => "date", "narrow" => true}, Dowser.Client.Codec.BuilderFixtures.FieldB
end
