defmodule RecompileBuster.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/MrYawe/recompile_buster"

  def project do
    [
      app: :recompile_buster,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
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
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Mix task that analyzes your xref graph to find modules causing excessive recompilation, and helps you fix them."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
