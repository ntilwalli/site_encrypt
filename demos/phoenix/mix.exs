defmodule PhoenixDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_demo,
      version: "0.1.1",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PhoenixDemo.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.6"},
      {:jason, "~> 1.3"},
      {:plug_cowboy, "~> 2.5"},
      {:site_encrypt, path: "../.."}
    ]
  end
end
