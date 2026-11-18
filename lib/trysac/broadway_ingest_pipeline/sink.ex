defmodule Trysac.BroadwayIngestPipeline.Sink do
  @moduledoc """
  Behaviour for batch sinks receiving validated messages from `Trysac.BroadwayIngestPipeline.Pipeline`.
  """

  @type row :: %{
          id: String.t(),
          ts: String.t(),
          payload: term()
        }

  @doc """
  Writes a batch of rows idempotently into the target store.
  """
  @callback write_batch(rows :: [row()]) :: :ok | {:error, term()}
end
