# Factory-owned file: agents must not edit it. The library's dependencies are added by
# `elixir scripts/add_dependency.exs`; the version is the literal @version below (the release manager sets it).
defmodule Trysac.BroadwayIngestPipeline.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Trysac/u957-broadway-ingest-pipeline"
  # A sigil without interpolation, so any description text is literal.
  @description ~S"""
  Broadway ingestion pipeline over a lease-based queue with idempotent Postgres-style batch upserts, exponential retry backoff and a dead-letter store that loses nothing on crashes
  """

  def project do
    [
      app: :trysac_broadway_ingest_pipeline,
      version: @version,
      elixir: "~> 1.20",
      description: String.trim(@description),
      package: package(),
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      deps_path: work_path("deps"),
      build_path: work_path("_build"),
      # The tests gate (scripts/check.exs) reads the total and enforces the threshold; the report goes to a
      # temporary folder chosen by the gate, never into the repository.
      test_coverage: [
        output: System.get_env("FABRICA_COVERAGE_DIR", "cover"),
        summary: [threshold: 0]
      ],
      # The project PLT lives beside the build, so later runs reuse it.
      dialyzer: [
        plt_local_path: work_path("_build/plts"),
        flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # The factory's gates image sets FABRICA_MIX_WORK: deps/ and _build/ then live in its cache volume, one folder per
  # application, instead of the repository mounted from the host (unpacking Hex packages on a Windows host mount is
  # too slow). Everywhere else they are the usual deps/ and _build/ of the repository, ignored by git.
  defp work_path(dir) do
    case System.get_env("FABRICA_MIX_WORK") do
      nil -> dir
      work -> Path.join([work, "trysac_broadway_ingest_pipeline", dir])
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Source" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp deps do
    [
      {:broadway, ">= 1.3.0 and < 2.0.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.4", only: [:dev, :test]}
    ]
  end
end
