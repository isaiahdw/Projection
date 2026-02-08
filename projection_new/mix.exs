defmodule ProjectionNew.MixProject do
  use Mix.Project

  def project do
    [
      app: :projection_new,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Mix project generator for Projection + Slint starter apps.",
      source_url: "https://github.com/isaiahp/projection",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/isaiahp/projection"},
      files: ~w(lib priv mix.exs README.md LICENSE .formatter.exs)
    ]
  end
end
