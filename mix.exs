defmodule AlloydbConnector.MixProject do
  use Mix.Project

  def project do
    [
      app: :alloydb_connector,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AlloydbConnector.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:protobuf, "~> 0.12.0"},
      {:google_protos, "~> 0.3.0"},
      {:postgrex, github: "pinetops/postgrex", branch: "iam-support"},
      {:goth, github: "pinetops/goth", branch: "alloydb-support"},
      {:jason, "~> 1.4"},
      {:httpoison, "~> 2.0"},
      {:hackney, "~> 1.18"}
    ]
  end
end
