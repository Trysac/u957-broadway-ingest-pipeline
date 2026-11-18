defmodule Trysac.BroadwayIngestPipeline.LeaseQueue do
  @moduledoc """
  In-memory lease-based message queue with bounded capacity, body size enforcement,
  visibility timeouts, delayed nacks, and a dead-letter store.
  """

  use GenServer

  alias Trysac.BroadwayIngestPipeline.Error
  alias Trysac.BroadwayIngestPipeline.Lease

  @default_lease_ms 30_000
  @default_max_messages 100_000
  @default_max_body_bytes 1_048_576

  @type queue :: GenServer.server()
  @type stats :: %{
          ready: non_neg_integer(),
          leased: non_neg_integer(),
          acked: non_neg_integer(),
          dead: non_neg_integer()
        }
  @type dead_entry :: %{
          message_id: String.t(),
          reason: term(),
          attempts: pos_integer()
        }

  defmodule Item do
    @moduledoc false
    @enforce_keys [:message_id, :body, :attempt, :available_at, :seq]
    defstruct [:message_id, :body, :attempt, :available_at, :seq]
  end

  defmodule LeasedItem do
    @moduledoc false
    @enforce_keys [:lease_id, :item, :expires_at]
    defstruct [:lease_id, :item, :expires_at]
  end

  @doc """
  Starts a `LeaseQueue` GenServer.

  ## Options

    * `:name` - optional process registration name.
    * `:lease_ms` - lease duration in milliseconds (default `30_000`).
    * `:max_messages` - maximum active (ready + leased + dead) messages (default `100_000`).
    * `:max_body_bytes` - maximum message body size in bytes (default `1_048_576`).
    * `:clock` - 0-arity function returning current milliseconds.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    config = validate_opts!(opts)

    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, config)
      {:ok, name} -> GenServer.start_link(__MODULE__, config, name: name)
      :error -> GenServer.start_link(__MODULE__, config)
    end
  end

  @doc """
  Enqueues a list of raw binary message bodies.

  Returns `{:ok, [message_id]}` or raises `Trysac.BroadwayIngestPipeline.Error`
  with `:message_too_large` or `:queue_full`.
  """
  @spec enqueue(queue(), [String.t()]) :: {:ok, [String.t()]}
  def enqueue(queue, bodies) when is_list(bodies) do
    case GenServer.call(queue, {:enqueue, bodies}, :infinity) do
      {:ok, ids} -> {:ok, ids}
      {:error, %Error{} = err} -> raise err
    end
  end

  @doc """
  Leases up to `count` ready messages whose visibility delay has elapsed.
  """
  @spec lease(queue(), non_neg_integer()) :: [Lease.t()]
  def lease(_, 0), do: []

  def lease(queue, count) when is_integer(count) and count > 0 do
    GenServer.call(queue, {:lease, count}, :infinity)
  end

  @doc """
  Acknowledges a list of lease IDs.

  Raises `Trysac.BroadwayIngestPipeline.Error` with `:unknown_lease` if any lease ID
  is not currently active.
  """
  @spec ack(queue(), [String.t()]) :: :ok
  def ack(_, []), do: :ok

  def ack(queue, lease_ids) when is_list(lease_ids) do
    case GenServer.call(queue, {:ack, lease_ids}, :infinity) do
      :ok -> :ok
      {:error, %Error{} = err} -> raise err
    end
  end

  @doc """
  Negatively acknowledges a list of lease IDs, returning them to the ready queue
  after `delay_ms` milliseconds with `attempt + 1`.

  Raises `Trysac.BroadwayIngestPipeline.Error` with `:unknown_lease` if any lease ID
  is not currently active.
  """
  @spec nack(queue(), [String.t()], non_neg_integer()) :: :ok
  def nack(_, [], _), do: :ok

  def nack(queue, lease_ids, delay_ms)
      when is_list(lease_ids) and is_integer(delay_ms) and delay_ms >= 0 do
    case GenServer.call(queue, {:nack, lease_ids, delay_ms}, :infinity) do
      :ok -> :ok
      {:error, %Error{} = err} -> raise err
    end
  end

  @doc """
  Moves an active lease into the dead-letter store with `reason`.

  Raises `Trysac.BroadwayIngestPipeline.Error` with `:unknown_lease` if the lease ID
  is not currently active.
  """
  @spec dead_letter(queue(), String.t(), term()) :: :ok
  def dead_letter(queue, lease_id, reason) when is_binary(lease_id) do
    case GenServer.call(queue, {:dead_letter, lease_id, reason}, :infinity) do
      :ok -> :ok
      {:error, %Error{} = err} -> raise err
    end
  end

  @doc """
  Sweeps expired leases and returns them to the ready state with `attempt + 1`.
  Returns the number of expired leases returned to ready.
  """
  @spec expire(queue()) :: non_neg_integer()
  def expire(queue) do
    GenServer.call(queue, :expire, :infinity)
  end

  @doc """
  Returns counts for `:ready`, `:leased`, `:acked`, and `:dead` messages.
  """
  @spec stats(queue()) :: stats()
  def stats(queue) do
    GenServer.call(queue, :stats, :infinity)
  end

  @doc """
  Returns the list of dead-lettered message entries in order of dead-lettering.
  """
  @spec dead(queue()) :: [dead_entry()]
  def dead(queue) do
    GenServer.call(queue, :dead, :infinity)
  end

  # GenServer callbacks

  @impl true
  def init(config) do
    state = %{
      lease_ms: config.lease_ms,
      max_messages: config.max_messages,
      max_body_bytes: config.max_body_bytes,
      clock: config.clock,
      next_msg_seq: 1,
      next_lease_seq: 1,
      ready: :gb_trees.empty(),
      leased: %{},
      acked_count: 0,
      dead_rev: [],
      dead_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, []}, _, state) do
    {:reply, {:ok, []}, state}
  end

  def handle_call({:enqueue, bodies}, _, state) do
    case validate_enqueue(bodies, state) do
      :ok ->
        now = state.clock.()
        {ids_rev, ready, next_seq} = insert_bodies(bodies, now, state.ready, state.next_msg_seq)
        new_state = %{state | ready: ready, next_msg_seq: next_seq}
        {:reply, {:ok, Enum.reverse(ids_rev)}, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:lease, count}, _, state) do
    now = state.clock.()

    {leases_rev, ready, leased, next_lease_seq} =
      take_ready(state.ready, state.leased, count, now, state.lease_ms, state.next_lease_seq, [])

    new_state = %{
      state
      | ready: ready,
        leased: leased,
        next_lease_seq: next_lease_seq
    }

    {:reply, Enum.reverse(leases_rev), new_state}
  end

  def handle_call({:ack, lease_ids}, _, state) do
    case verify_leases(lease_ids, state.leased) do
      :ok ->
        unique_ids = Enum.uniq(lease_ids)
        leased = Map.drop(state.leased, unique_ids)
        acked_count = state.acked_count + length(unique_ids)
        {:reply, :ok, %{state | leased: leased, acked_count: acked_count}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:nack, lease_ids, delay_ms}, _, state) do
    case verify_leases(lease_ids, state.leased) do
      :ok ->
        now = state.clock.()
        available_at = now + delay_ms
        unique_ids = Enum.uniq(lease_ids)

        {leased, ready} =
          Enum.reduce(unique_ids, {state.leased, state.ready}, fn lid, {l_acc, r_acc} ->
            {%LeasedItem{item: %Item{} = item}, l_rest} = Map.pop!(l_acc, lid)
            updated_item = %Item{item | attempt: item.attempt + 1, available_at: available_at}
            r_next = :gb_trees.insert({updated_item.available_at, updated_item.seq}, updated_item, r_acc)
            {l_rest, r_next}
          end)

        {:reply, :ok, %{state | leased: leased, ready: ready}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:dead_letter, lease_id, reason}, _, state) do
    case Map.pop(state.leased, lease_id) do
      {nil, _} ->
        err = Error.new(:unknown_lease, "unknown lease id: #{Error.snippet(lease_id)}")
        {:reply, {:error, err}, state}

      {%LeasedItem{item: item}, leased} ->
        entry = %{
          message_id: item.message_id,
          reason: reason,
          attempts: item.attempt
        }

        new_state = %{
          state
          | leased: leased,
            dead_rev: [entry | state.dead_rev],
            dead_count: state.dead_count + 1
        }

        {:reply, :ok, new_state}
    end
  end

  def handle_call(:expire, _, state) do
    now = state.clock.()
    expired = find_expired(state.leased, now)
    {leased, ready} = return_expired_to_ready(expired, state.leased, state.ready, now)
    {:reply, length(expired), %{state | leased: leased, ready: ready}}
  end

  def handle_call(:stats, _, state) do
    reply = %{
      ready: :gb_trees.size(state.ready),
      leased: map_size(state.leased),
      acked: state.acked_count,
      dead: state.dead_count
    }

    {:reply, reply, state}
  end

  def handle_call(:dead, _, state) do
    {:reply, Enum.reverse(state.dead_rev), state}
  end

  # Private helpers

  defp find_expired(leased, now) do
    leased
    |> Map.values()
    |> Enum.filter(fn %LeasedItem{expires_at: exp} -> exp <= now end)
    |> Enum.sort_by(fn %LeasedItem{item: item} -> item.seq end)
  end

  defp return_expired_to_ready(expired, leased, ready, now) do
    Enum.reduce(expired, {leased, ready}, fn %LeasedItem{lease_id: lid, item: %Item{} = item}, {l_acc, r_acc} ->
      l_next = Map.delete(l_acc, lid)
      updated_item = %Item{item | attempt: item.attempt + 1, available_at: now}
      r_next = :gb_trees.insert({updated_item.available_at, updated_item.seq}, updated_item, r_acc)
      {l_next, r_next}
    end)
  end

  defp validate_opts!(opts) do
    lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)
    max_messages = Keyword.get(opts, :max_messages, @default_max_messages)
    max_body_bytes = Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    if not is_integer(lease_ms) or lease_ms <= 0 do
      raise Error.new(:invalid_option, "lease_ms must be a positive integer")
    end

    if not is_integer(max_messages) or max_messages <= 0 do
      raise Error.new(:invalid_option, "max_messages must be a positive integer")
    end

    if not is_integer(max_body_bytes) or max_body_bytes <= 0 do
      raise Error.new(:invalid_option, "max_body_bytes must be a positive integer")
    end

    if not is_function(clock, 0) do
      raise Error.new(:invalid_option, "clock must be a 0-arity function")
    end

    %{
      lease_ms: lease_ms,
      max_messages: max_messages,
      max_body_bytes: max_body_bytes,
      clock: clock
    }
  end

  defp validate_enqueue(bodies, state) do
    oversized =
      Enum.find(bodies, fn body ->
        not is_binary(body) or byte_size(body) > state.max_body_bytes
      end)

    cond do
      oversized != nil and not is_binary(oversized) ->
        {:error, Error.new(:invalid_option, "message body must be a binary")}

      oversized != nil ->
        {:error,
         Error.new(
           :message_too_large,
           "message body size #{byte_size(oversized)} exceeds max_body_bytes #{state.max_body_bytes}"
         )}

      current_depth(state) + length(bodies) > state.max_messages ->
        {:error,
         Error.new(
           :queue_full,
           "queue capacity #{state.max_messages} exceeded"
         )}

      true ->
        :ok
    end
  end

  defp current_depth(state) do
    :gb_trees.size(state.ready) + map_size(state.leased)
  end

  defp insert_bodies(bodies, now, ready, next_seq) do
    Enum.reduce(bodies, {[], ready, next_seq}, fn body, {ids_acc, r_acc, seq} ->
      msg_id = "msg_#{seq}"

      item = %Item{
        message_id: msg_id,
        body: body,
        attempt: 1,
        available_at: now,
        seq: seq
      }

      r_next = :gb_trees.insert({now, seq}, item, r_acc)
      {[msg_id | ids_acc], r_next, seq + 1}
    end)
  end

  defp take_ready(ready, leased, 0, _, _, next_lease_seq, acc) do
    {acc, ready, leased, next_lease_seq}
  end

  defp take_ready(ready, leased, remaining, now, lease_ms, next_lease_seq, acc) do
    case :gb_trees.is_empty(ready) do
      true ->
        {acc, ready, leased, next_lease_seq}

      false ->
        {{avail_at, _}, item, ready_rest} = :gb_trees.take_smallest(ready)

        if avail_at <= now do
          lease_id = "lease_#{next_lease_seq}"

          lease = %Lease{
            id: lease_id,
            message_id: item.message_id,
            body: item.body,
            attempt: item.attempt
          }

          leased_item = %LeasedItem{
            lease_id: lease_id,
            item: item,
            expires_at: now + lease_ms
          }

          leased_next = Map.put(leased, lease_id, leased_item)

          take_ready(
            ready_rest,
            leased_next,
            remaining - 1,
            now,
            lease_ms,
            next_lease_seq + 1,
            [lease | acc]
          )
        else
          {acc, ready, leased, next_lease_seq}
        end
    end
  end

  defp verify_leases(lease_ids, leased) do
    case Enum.find(lease_ids, fn lid -> not is_binary(lid) or not Map.has_key?(leased, lid) end) do
      nil ->
        :ok

      unknown ->
        {:error, Error.new(:unknown_lease, "unknown lease id: #{Error.snippet(unknown)}")}
    end
  end
end
