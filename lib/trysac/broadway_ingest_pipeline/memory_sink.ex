defmodule Trysac.BroadwayIngestPipeline.MemorySink do
  @moduledoc """
  Agent-backed in-memory sink implementing primary-key (`id`) insert-or-ignore semantics
  and failure injection for testing retry and crash-recovery flows.
  """

  use Agent

  alias Trysac.BroadwayIngestPipeline.Sink

  @type sink :: Agent.agent()

  @doc """
  Starts an in-memory sink Agent.

  ## Options

    * `:name` - optional registered name.
    * `:on_write` - optional 1-arity callback invoked after a batch commits with the total row count.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    on_write = Keyword.get(opts, :on_write)

    initial = %{
      rows_by_id: %{},
      order_rev: [],
      fail_remaining: 0,
      write_calls: 0,
      on_write: on_write
    }

    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> Agent.start_link(fn -> initial end)
      {:ok, name} -> Agent.start_link(fn -> initial end, name: name)
      :error -> Agent.start_link(fn -> initial end)
    end
  end

  @doc """
  Returns all stored rows in insertion order.
  """
  @spec rows(sink()) :: [Sink.row()]
  def rows(sink) do
    Agent.get(sink, fn state ->
      state.order_rev
      |> Enum.reverse()
      |> Enum.map(&Map.fetch!(state.rows_by_id, &1))
    end)
  end

  @doc """
  Returns the number of `write_batch/2` calls received by the sink.
  """
  @spec write_calls(sink()) :: non_neg_integer()
  def write_calls(sink) do
    Agent.get(sink, & &1.write_calls)
  end

  @doc """
  Configures the sink to fail the next `count` calls to `write_batch/2` with `{:error, :unavailable}`.
  """
  @spec fail_next(sink(), non_neg_integer()) :: :ok
  def fail_next(sink, count) when is_integer(count) and count >= 0 do
    Agent.update(sink, fn state -> %{state | fail_remaining: count} end)
  end

  @doc """
  Writes a batch of rows with `ON CONFLICT (id) DO NOTHING` semantics.
  """
  @spec write_batch(sink(), [Sink.row()]) :: :ok | {:error, :unavailable}
  def write_batch(sink, rows) when is_list(rows) do
    result = Agent.get_and_update(sink, &apply_write_batch(&1, rows))

    case result do
      {:ok, total_rows, on_write} when is_function(on_write, 1) ->
        on_write.(total_rows)
        :ok

      {:ok, _, _} ->
        :ok

      {:error, :unavailable} = err ->
        err
    end
  end

  defp apply_write_batch(%{fail_remaining: rem} = state, _) when rem > 0 do
    next_state = %{
      state
      | fail_remaining: rem - 1,
        write_calls: state.write_calls + 1
    }

    {{:error, :unavailable}, next_state}
  end

  defp apply_write_batch(state, rows) do
    {rows_by_id, order_rev} = Enum.reduce(rows, {state.rows_by_id, state.order_rev}, &insert_row/2)

    next_state = %{
      state
      | rows_by_id: rows_by_id,
        order_rev: order_rev,
        write_calls: state.write_calls + 1
    }

    {{:ok, map_size(rows_by_id), state.on_write}, next_state}
  end

  defp insert_row(row, {map_acc, ord_acc}) do
    id = Map.fetch!(row, :id)

    if Map.has_key?(map_acc, id) do
      {map_acc, ord_acc}
    else
      {Map.put(map_acc, id, row), [id | ord_acc]}
    end
  end
end
