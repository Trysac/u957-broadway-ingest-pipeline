defmodule Trysac.BroadwayIngestPipeline.Pipeline do
  @moduledoc """
  Broadway ingestion pipeline that decodes and validates JSON messages in processors,
  writes batches to a sink in batchers, and acknowledges or retries via `QueueProducer`.
  """

  use Broadway

  alias Broadway.BatchInfo
  alias Broadway.Message
  alias Trysac.BroadwayIngestPipeline.Error
  alias Trysac.BroadwayIngestPipeline.MemorySink
  alias Trysac.BroadwayIngestPipeline.QueueProducer

  @default_batch_size 100
  @default_batch_timeout 1_000
  @default_processors 4
  @default_batchers 2
  @default_max_attempts 5
  @default_backoff_base_ms 100
  @default_backoff_max_ms 30_000
  @default_poll_ms 100

  @allowed_keys [
    :name,
    :queue,
    :sink,
    :batch_size,
    :batch_timeout,
    :processors,
    :batchers,
    :max_attempts,
    :backoff_base_ms,
    :backoff_max_ms,
    :poll_ms,
    :on_event
  ]

  @doc """
  Starts a Broadway ingestion pipeline linked to the current process.

  ## Options

    * `:name` - Broadway pipeline atom name (optional). Without it the pipeline registers under a
      unique `{:via, :global, {#{inspect(__MODULE__)}, reference}}` name, so several unnamed
      pipelines can run at once and `poll/1` accepts the returned pid.
    * `:queue` - required `LeaseQueue` server reference.
    * `:sink` - required sink reference (`pid`, atom name, `{module, arg}`, 1-arity fun, or module implementing `Sink`).
    * `:batch_size` - positive integer batch size (default `100`).
    * `:batch_timeout` - positive integer batch timeout in ms (default `1_000`).
    * `:processors` - positive integer processor concurrency (default `4`).
    * `:batchers` - positive integer batcher concurrency (default `2`).
    * `:max_attempts` - positive integer maximum delivery attempts (default `5`).
    * `:backoff_base_ms` - positive integer base backoff in ms (default `100`).
    * `:backoff_max_ms` - positive integer maximum backoff in ms (default `30_000`).
    * `:poll_ms` - positive integer producer poll interval in ms (default `100`).
    * `:on_event` - optional 1-arity callback receiving `%{type: atom(), count: pos_integer(), attempt: pos_integer()}`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    config = validate_opts!(opts)

    producer_opts = [
      queue: config.queue,
      poll_ms: config.poll_ms,
      max_attempts: config.max_attempts,
      backoff_base_ms: config.backoff_base_ms,
      backoff_max_ms: config.backoff_max_ms,
      on_event: config.on_event
    ]

    broadway_opts = [
      name: config.name || {:via, :global, {__MODULE__, make_ref()}},
      context: %{sink: config.sink},
      producer: [
        module: {QueueProducer, producer_opts},
        concurrency: 1
      ],
      processors: [
        default: [
          concurrency: config.processors,
          max_demand: config.batch_size
        ]
      ],
      batchers: [
        default: [
          concurrency: config.batchers,
          batch_size: config.batch_size,
          batch_timeout: config.batch_timeout
        ]
      ]
    ]

    Broadway.start_link(__MODULE__, broadway_opts)
  end

  @doc """
  Triggers an immediate producer poll on a running pipeline, given its name or its pid.
  """
  @spec poll(GenServer.server()) :: :ok
  def poll(pipeline) do
    pipeline
    |> broadway_name()
    |> Broadway.producer_names()
    |> Enum.each(&QueueProducer.poll/1)

    :ok
  end

  defp broadway_name(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> name
      _ -> global_name(pid)
    end
  end

  defp broadway_name(name), do: name

  defp global_name(pid) do
    key =
      Enum.find(:global.registered_names(), fn
        {__MODULE__, ref} = key when is_reference(ref) -> :global.whereis_name(key) == pid
        _ -> false
      end)

    if key == nil do
      raise Error.new(:invalid_option, "no running pipeline for #{Error.snippet(pid)}")
    end

    {:via, :global, key}
  end

  @doc """
  Decodes and validates a raw JSON message body.

  Expected JSON object shape:
    * `"id"` - string of 1 to 64 characters
    * `"ts"` - valid ISO 8601 timestamp or date string
    * `"payload"` - any JSON value (key must be present)
  """
  @spec decode_and_validate(String.t()) ::
          {:ok, %{id: String.t(), ts: String.t(), payload: term()}} | {:error, :invalid_message}
  def decode_and_validate(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, map} when is_map(map) ->
        validate_decoded_map(map)

      _ ->
        {:error, :invalid_message}
    end
  end

  # Broadway callbacks

  # Stage names are registered through :global under `{pipeline_name, base_name}`, so neither a
  # named nor an unnamed pipeline creates atoms at runtime.
  @impl true
  def process_name({:via, _, term}, base_name), do: {:via, :global, {term, base_name}}
  def process_name(name, base_name) when is_atom(name), do: {:via, :global, {name, base_name}}

  @impl true
  def handle_message(_, %Message{data: body} = message, _) do
    case decode_and_validate(body) do
      {:ok, row} ->
        message
        |> Message.update_data(fn _ -> row end)
        |> Message.put_batcher(:default)

      {:error, :invalid_message} ->
        Message.failed(message, :invalid_message)
    end
  end

  @impl true
  def handle_batch(_, messages, %BatchInfo{}, %{sink: sink}) do
    rows = Enum.map(messages, & &1.data)

    case dispatch_sink(sink, rows) do
      :ok ->
        messages

      {:error, reason} ->
        Enum.map(messages, &Message.failed(&1, {:sink_error, reason}))
    end
  end

  # Private helpers

  defp dispatch_sink({module, arg}, rows) when is_atom(module) do
    module.write_batch(arg, rows)
  end

  defp dispatch_sink(sink, rows) when is_function(sink, 1) do
    sink.(rows)
  end

  defp dispatch_sink(sink, rows) when is_pid(sink) do
    MemorySink.write_batch(sink, rows)
  end

  defp dispatch_sink(sink, rows) when is_atom(sink) do
    if Code.ensure_loaded?(sink) and function_exported?(sink, :write_batch, 1) do
      sink.write_batch(rows)
    else
      MemorySink.write_batch(sink, rows)
    end
  end

  defp validate_decoded_map(map) do
    with {:ok, id} <- Map.fetch(map, "id"),
         true <- valid_id?(id),
         {:ok, ts} <- Map.fetch(map, "ts"),
         true <- valid_iso8601?(ts),
         true <- Map.has_key?(map, "payload") do
      {:ok, %{id: id, ts: ts, payload: Map.get(map, "payload")}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp valid_id?(id) when is_binary(id) do
    len = String.length(id)
    len >= 1 and len <= 64
  end

  defp valid_id?(_), do: false

  defp valid_iso8601?(ts) when is_binary(ts) and byte_size(ts) > 0 do
    case DateTime.from_iso8601(ts) do
      {:ok, _, _} ->
        true

      _ ->
        case NaiveDateTime.from_iso8601(ts) do
          {:ok, _} ->
            true

          _ ->
            match?({:ok, _}, Date.from_iso8601(ts))
        end
    end
  end

  defp valid_iso8601?(_), do: false

  defp validate_opts!(opts) do
    check_unknown_keys!(opts)

    name = validate_name!(Keyword.get(opts, :name))
    queue = validate_required!(opts, :queue)
    sink = validate_required!(opts, :sink)
    batch_size = validate_pos_int!(opts, :batch_size, @default_batch_size)
    batch_timeout = validate_pos_int!(opts, :batch_timeout, @default_batch_timeout)
    processors = validate_pos_int!(opts, :processors, @default_processors)
    batchers = validate_pos_int!(opts, :batchers, @default_batchers)
    max_attempts = validate_pos_int!(opts, :max_attempts, @default_max_attempts)
    backoff_base_ms = validate_pos_int!(opts, :backoff_base_ms, @default_backoff_base_ms)
    backoff_max_ms = validate_pos_int!(opts, :backoff_max_ms, @default_backoff_max_ms)
    poll_ms = validate_pos_int!(opts, :poll_ms, @default_poll_ms)
    on_event = validate_on_event!(Keyword.get(opts, :on_event, fn _ -> :ok end))

    if backoff_max_ms < backoff_base_ms do
      raise Error.new(:invalid_option, "backoff_max_ms must be >= backoff_base_ms")
    end

    %{
      name: name,
      queue: queue,
      sink: sink,
      batch_size: batch_size,
      batch_timeout: batch_timeout,
      processors: processors,
      batchers: batchers,
      max_attempts: max_attempts,
      backoff_base_ms: backoff_base_ms,
      backoff_max_ms: backoff_max_ms,
      poll_ms: poll_ms,
      on_event: on_event
    }
  end

  defp check_unknown_keys!(opts) do
    case Keyword.keys(opts) -- @allowed_keys do
      [] ->
        :ok

      [unknown | _] ->
        raise Error.new(:invalid_option, "unknown option: #{Error.snippet(unknown)}")
    end
  end

  defp validate_name!(nil), do: nil

  defp validate_name!(name) when is_atom(name), do: name

  defp validate_name!(other) do
    raise Error.new(:invalid_option, "name must be an atom, got: #{Error.snippet(other)}")
  end

  defp validate_required!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} when val != nil ->
        val

      _ ->
        raise Error.new(:invalid_option, "missing required option #{key}")
    end
  end

  defp validate_pos_int!(opts, key, default) do
    val = Keyword.get(opts, key, default)

    if is_integer(val) and val > 0 do
      val
    else
      raise Error.new(
              :invalid_option,
              "#{key} must be a positive integer, got: #{Error.snippet(val)}"
            )
    end
  end

  defp validate_on_event!(fun) when is_function(fun, 1), do: fun

  defp validate_on_event!(other) do
    raise Error.new(
            :invalid_option,
            "on_event must be a 1-arity function, got: #{Error.snippet(other)}"
          )
  end
end
