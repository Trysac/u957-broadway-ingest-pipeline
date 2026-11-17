defmodule Trysac.BroadwayIngestPipeline do
  @moduledoc """
  Broadway ingestion pipeline over a lease-based queue with idempotent Postgres-style batch upserts, exponential retry backoff and a dead-letter store that loses nothing on crashes

  The entry point of the library: its public modules live under `Trysac.BroadwayIngestPipeline`.
  """

  @doc """
  The library's version, read from the application specification (the release manager sets it in `mix.exs`).
  """
  @spec version() :: String.t()
  def version do
    :trysac_broadway_ingest_pipeline |> Application.spec(:vsn) |> to_string()
  end
end
