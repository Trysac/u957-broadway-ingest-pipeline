defmodule Trysac.BroadwayIngestPipeline.Lease do
  @moduledoc """
  Represents an active lease on a message from `Trysac.BroadwayIngestPipeline.LeaseQueue`.
  """

  @enforce_keys [:id, :message_id, :body, :attempt]
  defstruct [:id, :message_id, :body, :attempt]

  @type t :: %__MODULE__{
          id: String.t(),
          message_id: String.t(),
          body: String.t(),
          attempt: pos_integer()
        }
end
