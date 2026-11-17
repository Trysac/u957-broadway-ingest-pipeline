defmodule Trysac.BroadwayIngestPipeline.BlankInputError do
  @moduledoc """
  Raised when the input is empty or only whitespace, instead of returning an empty string.
  """

  defexception message: "input is blank"
end
