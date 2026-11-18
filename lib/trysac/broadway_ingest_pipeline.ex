defmodule Trysac.BroadwayIngestPipeline do
  @moduledoc """
  Broadway ingestion pipeline over a lease-based queue with idempotent
  Postgres-style batch upserts, exponential retry backoff and a dead-letter store.
  """

  @version Mix.Project.config()[:version]

  @doc """
  Returns the library version.

  ## Examples

      iex> Trysac.BroadwayIngestPipeline.version()
      "0.1.0"

  """
  @spec version() :: String.t()
  def version, do: @version
end
