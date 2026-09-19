defmodule Dowser.Client.MixProject do
  use Mix.Project

  @source_url "https://github.com/GRoguelon/dowser_client"
  @version "0.2.0"

  def project do
    [
      app: :dowser_client,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: dialyzer(),
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

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      name: :dowser_client,
      files: ~w[lib .formatter.exs mix.exs README* CHANGELOG* UPGRADE_GUIDE* LICENSE*],
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
      extras: ["README.md", "UPGRADE_GUIDE_0_2.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md", "UPGRADE_GUIDE_0_2.md"],
      groups_for_modules: [
        HTTP: [
          Dowser.Client.HTTP,
          Dowser.Client.HTTP.Profile,
          Dowser.Client.HTTP.SSL,
          Dowser.Client.HTTP.Stub
        ],
        JSON: [
          Dowser.Client.JSON,
          Dowser.Client.NDJSON
        ],
        Casting: [
          Dowser.Client.Decoder,
          Dowser.Client.Encoder,
          Dowser.CoreExt.Keyable
        ],
        Errors: [
          Dowser.Client.Error,
          Dowser.Client.HTTP.Error,
          Dowser.Client.JSON.Error
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      ## Dev
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end
end
