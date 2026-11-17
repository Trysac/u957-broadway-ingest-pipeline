defmodule Trysac.BroadwayIngestPipeline.Text do
  @moduledoc """
  Text helpers of this library.
  """

  alias Trysac.BroadwayIngestPipeline.BlankInputError

  @doc """
  Trims surrounding whitespace and lower-cases the ASCII letters of the text.

  Raises `Trysac.BroadwayIngestPipeline.BlankInputError` when nothing is left after trimming, instead of
  returning an empty string.

  ## Examples

      iex> Trysac.BroadwayIngestPipeline.Text.normalize("  Hello World ")
      "hello world"

  """
  @spec normalize(String.t()) :: String.t()
  def normalize(input) when is_binary(input) do
    case String.trim(input) do
      "" -> raise BlankInputError
      trimmed -> String.downcase(trimmed, :ascii)
    end
  end
end
