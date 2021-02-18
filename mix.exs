defmodule Lifx.Mixfile do
  use Mix.Project

  def project do
    [
      app: :lifx,
      version: "0.1.8",
      elixir: "~> 1.3",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Lifx, []},
      env: [
        multicast: {255, 255, 255, 255},
        #  Don't make this too small or the poller task will fall behind.
        poll_state_time: 5000,
        poll_discover_time: 10000,
        # Should be at least max_retries*wait_between_retry.
        max_api_timeout: 5000,
        max_retries: 3,
        wait_between_retry: 500,
        udp: Lifx.Udp
      ]
    ]
  end

  def description do
    """
    A Client for Lifx LAN API
    """
  end

  def package do
    [
      name: :lifx,
      files: ["lib", "priv", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["Christopher Steven Coté"],
      licenses: ["Apache License 2.0"],
      links: %{
        "GitHub" => "https://github.com/NationalAssociationOfRealtors/lifx",
        "Docs" => "https://github.com/NationalAssociationOfRealtors/lifx"
      }
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:dialyxir, "~> 1.1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      test: "test --no-start"
    ]
  end

  defp elixirc_paths(:test), do: ["test/support", "lib"]
  defp elixirc_paths(_), do: ["lib"]

  defp dialyzer do
    [
      ignore_warnings: "dialyzer.ignore-warnings",
      plt_core_path: "priv/plts",
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end
end
