defmodule Trysac.BroadwayIngestPipeline.Error do
  @moduledoc """
  Exception raised by `Trysac.BroadwayIngestPipeline` modules with a stable machine-readable `:code`.
  """

  @type code ::
          :invalid_option
          | :invalid_identifier
          | :message_too_large
          | :queue_full
          | :unknown_lease

  @type t :: %__MODULE__{
          code: code(),
          message: String.t()
        }

  defexception [:code, :message]

  @max_snippet_length 200

  @doc """
  Constructs a new `Trysac.BroadwayIngestPipeline.Error` with a truncated message.
  """
  @spec new(code(), String.t()) :: t()
  def new(code, message) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: truncate(message)}
  end

  @doc """
  Safely formats a snippet of input, capped at 200 characters.
  """
  @spec snippet(term()) :: String.t()
  def snippet(value) when is_binary(value), do: truncate(value)
  def snippet(value), do: value |> inspect(limit: 20, printable_limit: 200) |> truncate()

  defp truncate(str) do
    if String.length(str) > @max_snippet_length do
      String.slice(str, 0, @max_snippet_length)
    else
      str
    end
  end
end
