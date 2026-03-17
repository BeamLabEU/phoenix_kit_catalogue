defmodule PhoenixKitCatalogue.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :phoenix_kit_catalogue,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Catalogue module for PhoenixKit — manufacturers, suppliers, and product catalogues",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitCatalogue",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:phoenix_kit, path: "../phoenix_kit"},
      {:phoenix_live_view, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitCatalogue",
      source_ref: "v#{@version}"
    ]
  end
end
