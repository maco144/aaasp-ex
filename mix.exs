defmodule AaaspEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/maco144/aaasp-ex"

  def project do
    [
      app: :aaasp_ex,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Open-source Elixir agent execution engine powering AAASP.",
      package: package(),
      docs: [
        main: "AaaspEx",
        source_url: @source_url
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jido, "~> 2.0"},
      {:req_llm, "~> 1.6"},
      {:finch, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["LicenseRef-FSL-1.1-Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
