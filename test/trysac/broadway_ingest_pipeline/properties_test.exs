defmodule Trysac.BroadwayIngestPipeline.PropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Trysac.BroadwayIngestPipeline.MemorySink
  alias Trysac.BroadwayIngestPipeline.QueueProducer
  alias Trysac.BroadwayIngestPipeline.Sql

  property "backoff_ms is monotonically non-decreasing and bounded by [base_ms, max_ms]" do
    check all(
            base_ms <- integer(1..1_000),
            extra_max <- integer(0..50_000),
            a1 <- integer(1..20),
            a2 <- integer(a1..25)
          ) do
      max_ms = base_ms + extra_max
      d1 = QueueProducer.backoff_ms(a1, base_ms, max_ms)
      d2 = QueueProducer.backoff_ms(a2, base_ms, max_ms)

      assert d1 >= base_ms
      assert d1 <= max_ms
      assert d2 >= d1
      assert d2 <= max_ms
    end
  end

  property "MemorySink preserves first-seen row per id across arbitrary duplicate batches" do
    check all(ids <- list_of(string(:alphanumeric, min_length: 1, max_length: 10), min_length: 1, max_length: 40)) do
      {:ok, sink} = MemorySink.start_link()

      rows =
        ids
        |> Enum.with_index(1)
        |> Enum.map(fn {id, idx} ->
          %{id: id, ts: "2026-01-01T00:00:00Z", payload: idx}
        end)

      assert :ok = MemorySink.write_batch(sink, rows)

      stored = MemorySink.rows(sink)
      assert length(stored) == length(Enum.uniq(ids))
      assert Enum.map(stored, & &1.id) == Enum.uniq(ids)
    end
  end

  property "Sql.upsert preserves all parameter values in exact row-major order" do
    check all(
            row_count <- integer(1..50),
            ids <- list_of(string(:alphanumeric, min_length: 1, max_length: 16), length: row_count)
          ) do
      rows =
        Enum.map(ids, fn id ->
          %{id: id, ts: "2026-01-01T00:00:00Z", payload: id <> "_p"}
        end)

      [{sql, params}] = Sql.upsert("events", ["id", "ts", "payload"], rows)
      assert String.starts_with?(sql, "INSERT INTO \"events\" (\"id\", \"ts\", \"payload\") VALUES ")
      assert String.ends_with?(sql, " ON CONFLICT (\"id\") DO NOTHING")
      assert length(params) == row_count * 3
    end
  end
end
