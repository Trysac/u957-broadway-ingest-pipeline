defmodule Trysac.BroadwayIngestPipeline.PipelineTest do
  use ExUnit.Case, async: true

  alias Trysac.BroadwayIngestPipeline.Error
  alias Trysac.BroadwayIngestPipeline.LeaseQueue
  alias Trysac.BroadwayIngestPipeline.MemorySink
  alias Trysac.BroadwayIngestPipeline.Pipeline
  alias Trysac.BroadwayIngestPipeline.QueueProducer
  alias Trysac.BroadwayIngestPipeline.Sql

  defp make_clock(initial \\ 1_000) do
    {:ok, agent} = Agent.start_link(fn -> initial end)
    read = fn -> Agent.get(agent, & &1) end
    advance = fn delta -> Agent.update(agent, &(&1 + delta)) end
    {read, advance}
  end

  defp valid_json(id, payload \\ %{"v" => 1}, ts \\ "2026-01-01T00:00:00Z") do
    JSON.encode!(%{"id" => id, "ts" => ts, "payload" => payload})
  end

  # Polls `fun` every 5 ms for up to about 5 seconds.
  defp await_condition(fun, attempts \\ 1_000) do
    if fun.() do
      :ok
    else
      if attempts <= 0 do
        flunk("condition was not met in time")
      else
        Process.sleep(5)
        await_condition(fun, attempts - 1)
      end
    end
  end

  describe "acceptance criterion 1: 1_000 valid messages" do
    test "ingests 1_000 messages in 10 batches of 100 and updates queue stats" do
      {clock, _} = make_clock()
      {:ok, queue} = LeaseQueue.start_link(clock: clock)

      test_pid = self()

      {:ok, sink} =
        MemorySink.start_link(
          on_write: fn total ->
            if total == 1_000, do: send(test_pid, :all_committed)
          end
        )

      messages = for i <- 1..1_000, do: valid_json("id-#{i}", %{"seq" => i})
      assert {:ok, msg_ids} = LeaseQueue.enqueue(queue, messages)
      assert length(msg_ids) == 1_000

      {:ok, pipeline} =
        Pipeline.start_link(
          queue: queue,
          sink: sink,
          batch_size: 100,
          batch_timeout: 50,
          processors: 1,
          batchers: 1
        )

      assert_receive :all_committed, 5_000

      await_condition(fn ->
        LeaseQueue.stats(queue) == %{ready: 0, leased: 0, acked: 1_000, dead: 0}
      end)

      assert length(MemorySink.rows(sink)) == 1_000
      assert LeaseQueue.stats(queue) == %{ready: 0, leased: 0, acked: 1_000, dead: 0}
      assert MemorySink.write_calls(sink) == 10

      Supervisor.stop(pipeline)
    end
  end

  describe "acceptance criterion 2: crash safety between commit and ack" do
    test "kills pipeline with Process.exit(pid, :kill) after 400 rows committed before ack, expires at +30_001 ms, and stores 1_000 distinct ids" do
      {clock, advance} = make_clock(10_000)
      {:ok, queue} = LeaseQueue.start_link(lease_ms: 30_000, clock: clock)

      test_pid = self()
      {:ok, gate} = Agent.start_link(fn -> :trap_at_400 end)

      {:ok, sink} =
        MemorySink.start_link(
          on_write: fn total ->
            mode = Agent.get(gate, & &1)

            if mode == :trap_at_400 and total == 400 do
              send(test_pid, {:reached_400, self()})

              receive do
                :continue -> :ok
              end
            end
          end
        )

      messages = for i <- 1..1_000, do: valid_json("evt-#{i}", %{"i" => i})
      {:ok, _} = LeaseQueue.enqueue(queue, messages)

      {:ok, pipeline1} =
        Pipeline.start_link(
          name: :crash_safety_pipeline_1,
          queue: queue,
          sink: sink,
          batch_size: 100,
          batch_timeout: 20,
          processors: 1,
          batchers: 1
        )

      producers = Broadway.producer_names(:crash_safety_pipeline_1)
      assert_receive {:reached_400, batcher_pid}, 5_000

      assert length(MemorySink.rows(sink)) == 400
      stats_before_kill = LeaseQueue.stats(queue)
      assert stats_before_kill.leased >= 100
      assert stats_before_kill.acked < 400

      Process.unlink(pipeline1)
      ref = Process.monitor(pipeline1)
      Process.exit(pipeline1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pipeline1, :killed}, 5_000

      # A crashed node leaves no stage behind: kill the batch processor stuck in the sink (it
      # never acks its batch) and wait until the old producer is gone, so it cannot lease the
      # messages that expire below.
      Process.exit(batcher_pid, :kill)
      await_condition(fn -> Enum.all?(producers, &(GenServer.whereis(&1) == nil)) end)

      Agent.update(gate, fn _ -> :open end)
      advance.(30_001)
      expired_count = LeaseQueue.expire(queue)
      assert expired_count >= 100

      {:ok, pipeline2} =
        Pipeline.start_link(
          queue: queue,
          sink: sink,
          batch_size: 100,
          batch_timeout: 20,
          processors: 2,
          batchers: 2
        )

      Pipeline.poll(pipeline2)

      await_condition(fn ->
        s = LeaseQueue.stats(queue)
        s.ready == 0 and s.leased == 0 and length(MemorySink.rows(sink)) == 1_000
      end)

      rows = MemorySink.rows(sink)
      assert length(rows) == 1_000
      distinct_ids = rows |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.size(distinct_ids) == 1_000

      for i <- 1..1_000 do
        assert MapSet.member?(distinct_ids, "evt-#{i}")
      end

      Supervisor.stop(pipeline2)
    end
  end

  describe "acceptance criterion 3: exponential backoff retries" do
    test "MemorySink.fail_next(sink, 2) nacks with 100 and 200 ms delays and commits on attempt 3" do
      {clock, advance} = make_clock(5_000)
      {:ok, queue} = LeaseQueue.start_link(clock: clock)
      {:ok, sink} = MemorySink.start_link()

      MemorySink.fail_next(sink, 2)

      test_pid = self()
      on_event = fn evt -> send(test_pid, {:pipeline_event, evt}) end

      {:ok, _} = LeaseQueue.enqueue(queue, [valid_json("retry-1"), valid_json("retry-2")])

      {:ok, pipeline} =
        Pipeline.start_link(
          queue: queue,
          sink: sink,
          batch_size: 2,
          batch_timeout: 20,
          processors: 1,
          batchers: 1,
          poll_ms: 10_000,
          on_event: on_event
        )

      assert_receive {:pipeline_event, %{type: :batch_failed, count: 2, attempt: 1}}, 5_000

      advance.(99)
      assert LeaseQueue.lease(queue, 10) == []

      advance.(1)
      Pipeline.poll(pipeline)

      assert_receive {:pipeline_event, %{type: :batch_failed, count: 2, attempt: 2}}, 5_000

      advance.(199)
      assert LeaseQueue.lease(queue, 10) == []

      advance.(1)
      Pipeline.poll(pipeline)

      assert_receive {:pipeline_event, %{type: :batch_committed, count: 2, attempt: 3}}, 5_000

      assert length(MemorySink.rows(sink)) == 2
      assert LeaseQueue.stats(queue) == %{ready: 0, leased: 0, acked: 2, dead: 0}

      backoffs = for attempt <- 1..5, do: QueueProducer.backoff_ms(attempt, 100, 30_000)
      assert backoffs == [100, 200, 400, 800, 1_600]
      assert QueueProducer.backoff_ms(12, 100, 30_000) == 30_000

      Supervisor.stop(pipeline)
    end
  end

  describe "acceptance criterion 4: dead-lettering on attempt 5 and invalid messages" do
    test "moves messages failing on attempt 5 to dead-letter with :sink_failed and invalid messages at once with :invalid_message" do
      {clock, advance} = make_clock(1_000)
      {:ok, queue} = LeaseQueue.start_link(clock: clock)
      {:ok, sink} = MemorySink.start_link()

      test_pid = self()
      on_event = fn evt -> send(test_pid, {:event, evt}) end

      {:ok, [bad_json_id, no_id_msg_id, valid_msg_id]} =
        LeaseQueue.enqueue(queue, [
          "not-json{",
          JSON.encode!(%{"ts" => "2026-01-01T00:00:00Z", "payload" => 123}),
          valid_json("good-1", %{"ok" => true})
        ])

      {:ok, pipeline} =
        Pipeline.start_link(
          queue: queue,
          sink: sink,
          batch_size: 3,
          batch_timeout: 20,
          processors: 1,
          batchers: 1,
          max_attempts: 5,
          poll_ms: 10_000,
          on_event: on_event
        )

      assert_receive {:event, %{type: :dead_lettered, count: _, attempt: 1}}, 5_000
      assert_receive {:event, %{type: :batch_committed, count: 1, attempt: 1}}, 5_000

      await_condition(fn ->
        LeaseQueue.stats(queue) == %{ready: 0, leased: 0, acked: 1, dead: 2}
      end)

      assert [%{id: "good-1"}] = MemorySink.rows(sink)
      dead_initial = LeaseQueue.dead(queue)
      assert length(dead_initial) == 2
      assert Enum.all?(dead_initial, &(&1.reason == :invalid_message and &1.attempts == 1))

      assert Enum.map(dead_initial, & &1.message_id) |> Enum.sort() ==
               Enum.sort([bad_json_id, no_id_msg_id])

      refute valid_msg_id in Enum.map(dead_initial, & &1.message_id)

      MemorySink.fail_next(sink, 5)
      {:ok, [doomed_msg_id]} = LeaseQueue.enqueue(queue, [valid_json("doomed-1")])
      Pipeline.poll(pipeline)

      for {attempt, delay} <- [{1, 100}, {2, 200}, {3, 400}, {4, 800}] do
        assert_receive {:event, %{type: :batch_failed, count: 1, attempt: ^attempt}}, 5_000
        advance.(delay)
        Pipeline.poll(pipeline)
      end

      assert_receive {:event, %{type: :batch_failed, count: 1, attempt: 5}}, 5_000
      assert_receive {:event, %{type: :dead_lettered, count: 1, attempt: 5}}, 5_000

      dead_all = LeaseQueue.dead(queue)

      assert List.last(dead_all) == %{
               message_id: doomed_msg_id,
               reason: :sink_failed,
               attempts: 5
             }

      Supervisor.stop(pipeline)
    end
  end

  describe "acceptance criterion 5: Sql.upsert/3" do
    test "builds parameterized INSERT ... ON CONFLICT DO NOTHING and splits at 65_535 params" do
      rows = [
        %{id: "e1", ts: "2026-01-01T00:00:00Z", payload: "{\"a\":1}"},
        %{id: "e2", ts: "2026-01-01T00:00:01Z", payload: "{\"a\":2}"}
      ]

      assert [{sql, params}] = Sql.upsert("events", ["id", "ts", "payload"], rows)

      assert sql ==
               "INSERT INTO \"events\" (\"id\", \"ts\", \"payload\") VALUES ($1, $2, $3), ($4, $5, $6) ON CONFLICT (\"id\") DO NOTHING"

      assert params == [
               "e1",
               "2026-01-01T00:00:00Z",
               "{\"a\":1}",
               "e2",
               "2026-01-01T00:00:01Z",
               "{\"a\":2}"
             ]

      large_rows =
        for i <- 1..21_846 do
          %{"id" => "id_#{i}", "ts" => "2026-01-01T00:00:00Z", "payload" => i}
        end

      statements = Sql.upsert("events", ["id", "ts", "payload"], large_rows)
      assert length(statements) == 2

      [{sql1, params1}, {sql2, params2}] = statements
      assert length(params1) == 65_535
      assert length(params2) == 3
      assert String.ends_with?(sql1, "($65533, $65534, $65535) ON CONFLICT (\"id\") DO NOTHING")

      assert sql2 ==
               "INSERT INTO \"events\" (\"id\", \"ts\", \"payload\") VALUES ($1, $2, $3) ON CONFLICT (\"id\") DO NOTHING"
    end

    test "returns empty list when rows is empty" do
      assert Sql.upsert("events", ["id", "ts", "payload"], []) == []
    end
  end

  describe "acceptance criterion 6: typed errors" do
    test "raises Trysac.BroadwayIngestPipeline.Error with the specified code" do
      err_ident =
        assert_raise Error, fn ->
          Sql.upsert("events; drop", ["id", "ts", "payload"], [%{"id" => "1"}])
        end

      assert err_ident.code == :invalid_identifier

      {:ok, queue} = LeaseQueue.start_link()
      oversized_body = :binary.copy("a", 1_048_577)

      err_large =
        assert_raise Error, fn ->
          LeaseQueue.enqueue(queue, [oversized_body])
        end

      assert err_large.code == :message_too_large
      assert String.length(err_large.message) <= 200

      {:ok, full_queue} = LeaseQueue.start_link(max_messages: 100_000)
      batch_100k = List.duplicate("x", 100_000)
      assert {:ok, _} = LeaseQueue.enqueue(full_queue, batch_100k)

      err_full =
        assert_raise Error, fn ->
          LeaseQueue.enqueue(full_queue, ["x"])
        end

      assert err_full.code == :queue_full

      err_unknown =
        assert_raise Error, fn ->
          LeaseQueue.ack(queue, ["lease_nonexistent"])
        end

      assert err_unknown.code == :unknown_lease

      {:ok, sink} = MemorySink.start_link()

      err_opt =
        assert_raise Error, fn ->
          Pipeline.start_link(queue: queue, sink: sink, batch_size: 0)
        end

      assert err_opt.code == :invalid_option
    end
  end

  describe "acceptance criterion 7: on_event telemetry safety" do
    test "on_event receives only %{type, count, attempt} and never carries a message body or payload" do
      # Real monotonic clock: the 1 ms backoff must elapse for the retry to commit.
      {:ok, queue} = LeaseQueue.start_link()
      {:ok, sink} = MemorySink.start_link()
      MemorySink.fail_next(sink, 1)

      test_pid = self()
      on_event = fn event -> send(test_pid, {:telemetry_event, event}) end

      secret_marker = "SENSITIVE_PAYLOAD_MARKER_999"
      bad_body = "INVALID_JSON_#{secret_marker}"
      good_body = valid_json("safe-1", %{"secret" => secret_marker})

      {:ok, _} = LeaseQueue.enqueue(queue, [bad_body, good_body])

      {:ok, pipeline} =
        Pipeline.start_link(
          queue: queue,
          sink: sink,
          batch_size: 2,
          batch_timeout: 20,
          processors: 1,
          batchers: 1,
          backoff_base_ms: 1,
          poll_ms: 10,
          on_event: on_event
        )

      assert_receive {:telemetry_event, evt1}, 5_000
      assert_receive {:telemetry_event, evt2}, 5_000
      assert_receive {:telemetry_event, evt3}, 5_000

      for evt <- [evt1, evt2, evt3] do
        assert Map.keys(evt) |> Enum.sort() == [:attempt, :count, :type]
        assert evt.type in [:batch_committed, :batch_failed, :dead_lettered]
        assert is_integer(evt.count) and evt.count > 0
        assert is_integer(evt.attempt) and evt.attempt >= 1
        refute inspect(evt) =~ secret_marker
      end

      Supervisor.stop(pipeline)
    end
  end

  describe "edge cases and validation branches" do
    test "duplicate id inside one batch is stored once" do
      {:ok, queue} = LeaseQueue.start_link()
      {:ok, sink} = MemorySink.start_link()

      {:ok, _} =
        LeaseQueue.enqueue(queue, [
          valid_json("dup-id", %{"v" => 1}),
          valid_json("dup-id", %{"v" => 2})
        ])

      {:ok, pipeline} =
        Pipeline.start_link(
          queue: queue,
          sink: sink,
          batch_size: 2,
          batch_timeout: 20,
          processors: 1,
          batchers: 1
        )

      await_condition(fn ->
        LeaseQueue.stats(queue) == %{ready: 0, leased: 0, acked: 2, dead: 0}
      end)

      assert [%{id: "dup-id", payload: %{"v" => 1}}] = MemorySink.rows(sink)

      Supervisor.stop(pipeline)
    end

    test "empty enqueue returns {:ok, []} and nack of already acked lease raises :unknown_lease" do
      {:ok, queue} = LeaseQueue.start_link()
      assert LeaseQueue.enqueue(queue, []) == {:ok, []}
      assert LeaseQueue.lease(queue, 0) == []
      assert LeaseQueue.ack(queue, []) == :ok
      assert LeaseQueue.nack(queue, [], 50) == :ok

      {:ok, [_]} = LeaseQueue.enqueue(queue, [valid_json("m1")])
      [lease] = LeaseQueue.lease(queue, 1)
      assert :ok = LeaseQueue.ack(queue, [lease.id])

      err =
        assert_raise Error, fn ->
          LeaseQueue.nack(queue, [lease.id], 100)
        end

      assert err.code == :unknown_lease

      err_dl =
        assert_raise Error, fn ->
          LeaseQueue.dead_letter(queue, lease.id, :manual)
        end

      assert err_dl.code == :unknown_lease
    end

    test "lease that expires while its batch is still being written: direct ack raises :unknown_lease and redelivered copy is ignored by primary key" do
      {clock, advance} = make_clock(1_000)
      {:ok, queue} = LeaseQueue.start_link(lease_ms: 500, clock: clock)

      test_pid = self()
      {:ok, trap} = Agent.start_link(fn -> true end)

      {:ok, sink} =
        MemorySink.start_link(
          on_write: fn _ ->
            if Agent.get_and_update(trap, fn v -> {v, false} end) do
              send(test_pid, {:in_write_batch, self()})

              receive do
                :release_write -> :ok
              end
            end
          end
        )

      {:ok, _} = LeaseQueue.enqueue(queue, [valid_json("slow-1", %{"v" => "first"})])

      {:ok, pipeline} =
        Pipeline.start_link(
          queue: queue,
          sink: sink,
          batch_size: 1,
          batch_timeout: 10,
          processors: 1,
          batchers: 1,
          poll_ms: 50
        )

      assert_receive {:in_write_batch, blocked_pid}, 5_000

      advance.(501)
      assert LeaseQueue.expire(queue) == 1

      err =
        assert_raise Error, fn ->
          LeaseQueue.ack(queue, ["lease_1"])
        end

      assert err.code == :unknown_lease

      send(blocked_pid, :release_write)
      Pipeline.poll(pipeline)

      await_condition(fn ->
        s = LeaseQueue.stats(queue)
        s.ready == 0 and s.leased == 0 and s.acked == 1
      end)

      assert [%{id: "slow-1", payload: %{"v" => "first"}}] = MemorySink.rows(sink)

      Supervisor.stop(pipeline)
    end

    test "decode_and_validate handles boundary ids, timestamps, and missing fields" do
      max_id = String.duplicate("a", 64)
      too_long_id = String.duplicate("a", 65)

      assert {:ok, %{id: ^max_id}} =
               Pipeline.decode_and_validate(valid_json(max_id, nil, "2026-03-01"))

      assert {:ok, %{id: "naive"}} =
               Pipeline.decode_and_validate(valid_json("naive", [1, 2], "2026-03-01T12:00:00"))

      assert {:error, :invalid_message} =
               Pipeline.decode_and_validate(valid_json("", %{"a" => 1}))

      assert {:error, :invalid_message} =
               Pipeline.decode_and_validate(valid_json(too_long_id, %{"a" => 1}))

      assert {:error, :invalid_message} =
               Pipeline.decode_and_validate(valid_json("ok", %{"a" => 1}, "not-a-date"))

      assert {:error, :invalid_message} = Pipeline.decode_and_validate("[1, 2, 3]")
    end

    test "LeaseQueue, Pipeline, and Sql option and identifier validations" do
      assert_raise Error, fn -> LeaseQueue.start_link(lease_ms: 0) end
      assert_raise Error, fn -> LeaseQueue.start_link(max_messages: -1) end
      assert_raise Error, fn -> LeaseQueue.start_link(max_body_bytes: 0) end
      assert_raise Error, fn -> LeaseQueue.start_link(clock: :not_a_fun) end

      {:ok, q} = LeaseQueue.start_link(name: nil)
      {:ok, s} = MemorySink.start_link(name: nil)

      assert_raise Error, fn -> Pipeline.start_link(queue: q, sink: s, unknown_opt: 1) end
      assert_raise Error, fn -> Pipeline.start_link(queue: q, sink: s, name: "not_atom") end
      assert_raise Error, fn -> Pipeline.start_link(sink: s) end
      assert_raise Error, fn -> Pipeline.start_link(queue: q, sink: s, on_event: :bad) end

      assert_raise Error, fn ->
        Pipeline.start_link(queue: q, sink: s, backoff_base_ms: 500, backoff_max_ms: 100)
      end

      assert_raise Error, fn -> Sql.upsert("events", [], [%{id: "1"}]) end
      assert_raise Error, fn -> Sql.upsert("events", ["1bad"], [%{id: "1"}]) end

      long_err = Error.new(:invalid_option, String.duplicate("x", 250))
      assert String.length(long_err.message) == 200
      assert String.length(Error.snippet({:tuple, String.duplicate("y", 250)})) <= 200
    end
  end
end
