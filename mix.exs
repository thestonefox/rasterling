defmodule Rasterling.MixProject do
  use Mix.Project

  def project do
    [
      app: :rasterling,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: [],
      description: "Pure Elixir PNG, JPEG, GIF and BMP image decoding",
      package: [
        files: ~w(lib .formatter.exs mix.exs README.md LICENSE SECURITY.md),
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/thestonefox/rasterling"}
      ]
    ]
  end

  def application, do: []
end
