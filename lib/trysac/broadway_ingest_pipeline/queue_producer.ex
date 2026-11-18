defmodule Trysac.BroadwayIngestPipeline.QueueProducer do
  @moduledoc """
  `GenStage` producer and `Broadway.Acknowledger` for `Trysac.BroadwayIngestPipeline.LeaseQueue`.

  Leases messages on downstream demand, polls periodically when demand remains unsatisfied,
  and acknowledges messages only after the batch sink has committed.
  """

  @behaviour Broadway.Producer
  @behaviour Broadway.Acknowledger

  use GenStage

  alias Broadway.Message
  alias Trysac.BroadwayIngestPipeline.Error
  alias Trysac.BroadwayIngestPipeline.Lease
  alias Trysac.BroadwayIngestPipeline.LeaseQueue

  @default_poll_ms 100

  @doc """
  Computes the exponential backoff delay in milliseconds for a 1-based `attempt`,
  using `base_ms * 2^(attempt - 1)` capped at `max_ms`.
  """
  @spec backoff_ms(pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def backoff_ms(attempt, base_ms, max_ms)
      when is_integer(attempt) and attempt >= 1 and is_integer(base_ms) and base_ms > 0 and
             is_integer(max_ms) and max_ms >= base_ms do
    shift = min(attempt - 1, 30)
    delay = base_ms * Bitwise.bsl(1, shift)
    min(delay, max_ms)
  end

  @doc """
  Triggers an immediate poll on a producer process.
  """
  @spec poll(GenServer.server()) :: :ok
  def poll(producer) do
    case GenServer.whereis(producer) do
      nil ->
        :ok

      server ->
        send(server, :poll)
        :ok
    end
  end

  # GenStage callbacks

  @impl true
  def init(opts) do
    queue = Keyword.fetch!(opts, :queue)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    max_attempts = Keyword.get(opts, :max_attempts, 5)
    backoff_base_ms = Keyword.get(opts, :backoff_base_ms, 100)
    backoff_max_ms = Keyword.get(opts, :backoff_max_ms, 30_000)
    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)

    ack_ref = %{
      queue: queue,
      max_attempts: max_attempts,
      backoff_base_ms: backoff_base_ms,
      backoff_max_ms: backoff_max_ms,
      on_event: on_event
    }

    state = %{
      queue: queue,
      poll_ms: poll_ms,
      ack_ref: ack_ref,
      demand: 0,
      timer: nil,
      draining: false
    }

    {:producer, state}
  end

  @impl true
  def handle_demand(incoming_demand, state) when incoming_demand > 0 do
    dispatch_messages(%{state | demand: state.demand + incoming_demand})
  end

  @impl true
  def handle_info(:poll, state) do
    dispatch_messages(%{state | timer: nil})
  end

  def handle_info(_, state) do
    {:noreply, [], state}
  end

  @impl Broadway.Producer
  def prepare_for_draining(state) do
    :ok = cancel_poll(state.timer)

    {:noreply, [], %{state | timer: nil, draining: true}}
  end

  # Broadway.Acknowledger callback

  @impl Broadway.Acknowledger
  def ack(ack_ref, successful, failed) do
    handle_successful(ack_ref, successful)
    handle_failed(ack_ref, failed)
    :ok
  end

  # Internal producer dispatch

  defp cancel_poll(nil), do: :ok

  defp cancel_poll(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp dispatch_messages(%{draining: true} = state) do
    {:noreply, [], state}
  end

  defp dispatch_messages(%{demand: 0} = state) do
    {:noreply, [], state}
  end

  defp dispatch_messages(state) do
    leases = LeaseQueue.lease(state.queue, state.demand)
    messages = Enum.map(leases, &lease_to_broadway_message(&1, state.ack_ref))
    new_demand = state.demand - length(messages)

    timer =
      if new_demand > 0 and state.timer == nil and state.poll_ms > 0 do
        Process.send_after(self(), :poll, state.poll_ms)
      else
        state.timer
      end

    {:noreply, messages, %{state | demand: new_demand, timer: timer}}
  end

  defp lease_to_broadway_message(%Lease{} = lease, ack_ref) do
    ack_data = %{
      lease_id: lease.id,
      message_id: lease.message_id,
      attempt: lease.attempt
    }

    %Message{
      data: lease.body,
      metadata: %{
        lease_id: lease.id,
        message_id: lease.message_id,
        attempt: lease.attempt
      },
      acknowledger: {__MODULE__, ack_ref, ack_data}
    }
  end

  # Internal acknowledger helpers

  defp handle_successful(_, []), do: :ok

  defp handle_successful(ack_ref, successful) do
    Enum.each(successful, fn %Message{acknowledger: {_, _, ack_data}} ->
      safe_ack(ack_ref.queue, ack_data.lease_id)
    end)

    successful
    |> Enum.group_by(fn %Message{acknowledger: {_, _, ack_data}} -> ack_data.attempt end)
    |> Enum.each(fn {attempt, msgs} ->
      emit_event(ack_ref.on_event, :batch_committed, length(msgs), attempt)
    end)
  end

  defp handle_failed(_, []), do: :ok

  defp handle_failed(ack_ref, failed) do
    {invalid_msgs, sink_failed_msgs} =
      Enum.split_with(failed, fn %Message{status: status} ->
        match?({:failed, :invalid_message}, status)
      end)

    handle_invalid_messages(ack_ref, invalid_msgs)
    handle_sink_failed_messages(ack_ref, sink_failed_msgs)
  end

  defp handle_invalid_messages(_, []), do: :ok

  defp handle_invalid_messages(ack_ref, invalid_msgs) do
    Enum.each(invalid_msgs, fn %Message{acknowledger: {_, _, ack_data}} ->
      safe_dead_letter(ack_ref.queue, ack_data.lease_id, :invalid_message)
    end)

    invalid_msgs
    |> Enum.group_by(fn %Message{acknowledger: {_, _, ack_data}} -> ack_data.attempt end)
    |> Enum.each(fn {attempt, msgs} ->
      emit_event(ack_ref.on_event, :dead_lettered, length(msgs), attempt)
    end)
  end

  defp handle_sink_failed_messages(_, []), do: :ok

  defp handle_sink_failed_messages(ack_ref, sink_failed_msgs) do
    sink_failed_msgs
    |> Enum.group_by(fn %Message{acknowledger: {_, _, ack_data}} -> ack_data.attempt end)
    |> Enum.each(fn {attempt, msgs} ->
      process_failed_attempt(ack_ref, msgs, attempt)
    end)
  end

  # The queue is updated before the events are emitted, so an `on_event` observer always sees
  # the nacked or dead-lettered state of the messages it is told about.
  defp process_failed_attempt(ack_ref, msgs, attempt) do
    if attempt >= ack_ref.max_attempts do
      dead_letter_msgs(ack_ref, msgs)
      emit_event(ack_ref.on_event, :batch_failed, length(msgs), attempt)
      emit_event(ack_ref.on_event, :dead_lettered, length(msgs), attempt)
    else
      nack_msgs(ack_ref, msgs, attempt)
      emit_event(ack_ref.on_event, :batch_failed, length(msgs), attempt)
    end
  end

  defp dead_letter_msgs(ack_ref, msgs) do
    Enum.each(msgs, fn %Message{acknowledger: {_, _, ack_data}} ->
      safe_dead_letter(ack_ref.queue, ack_data.lease_id, :sink_failed)
    end)
  end

  defp nack_msgs(ack_ref, msgs, attempt) do
    delay = backoff_ms(attempt, ack_ref.backoff_base_ms, ack_ref.backoff_max_ms)

    Enum.each(msgs, fn %Message{acknowledger: {_, _, ack_data}} ->
      safe_nack(ack_ref.queue, ack_data.lease_id, delay)
    end)
  end

  defp safe_ack(queue, lease_id) do
    LeaseQueue.ack(queue, [lease_id])
  rescue
    e in Error ->
      if e.code == :unknown_lease, do: :ok, else: reraise(e, __STACKTRACE__)
  end

  defp safe_nack(queue, lease_id, delay) do
    LeaseQueue.nack(queue, [lease_id], delay)
  rescue
    e in Error ->
      if e.code == :unknown_lease, do: :ok, else: reraise(e, __STACKTRACE__)
  end

  defp safe_dead_letter(queue, lease_id, reason) do
    LeaseQueue.dead_letter(queue, lease_id, reason)
  rescue
    e in Error ->
      if e.code == :unknown_lease, do: :ok, else: reraise(e, __STACKTRACE__)
  end

  defp emit_event(on_event, type, count, attempt) when is_function(on_event, 1) do
    on_event.(%{type: type, count: count, attempt: attempt})
  end
end
