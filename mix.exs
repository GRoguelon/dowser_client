defmodule Dowser.Client.MixProject do
  use Mix.Project

  @source_url "https://github.com/GRoguelon/dowser_client"
  @version "0.1.1"

  def project do
    [
      app: :dowser_client,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      name: "Dowser.Client",
      description: "Low-level HTTP/JSON transport shared by the Dowser search-engine clients",
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      name: :dowser_client,
      files: ~w[lib .formatter.exs mix.exs README* CHANGELOG* LICENSE*],
      maintainers: ["Geoffrey Roguelon"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://dowser-client.hexdocs.pm/changelog.html",
        "Dowser.Elasticsearch" => "https://hex.pm/packages/dowser_elasticsearch"
      }
    ]
  end

  defp docs do
    [
      formatters: ["html"],
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        "HTTP Adapters": [
          Dowser.Client.HTTP.Adapter,
          Dowser.Client.HTTP.Httpc,
          Dowser.Client.HTTP.Req,
          Dowser.Client.HTTP.Hackney,
          Dowser.Client.HTTP.Stub
        ],
        "JSON Adapters": [
          Dowser.Client.NDJSON,
          Dowser.Client.JSON.Adapter,
          Dowser.Client.JSON.Native,
          Dowser.Client.JSON.Jason,
          Dowser.Client.JSON.Poison
        ],
        "Codec Adapters": [
          Dowser.Client.Codec,
          Dowser.Client.Codec.Default,
          Dowser.Client.Codec.Builder,
          Dowser.Client.Field
        ],
        Errors: [
          Dowser.Client.Error,
          Dowser.Client.Codec.Error,
          Dowser.Client.HTTP.Error,
          Dowser.Client.JSON.Error
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.7", optional: true},
      {:hackney, "~> 4.6", optional: true},
      {:jason, "~> 1.4", optional: true},
      {:poison, "~> 6.0", optional: true},

      ## Dev
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end
end
