defmodule Trysac.BroadwayIngestPipeline.Sql do
  @moduledoc """
  Pure SQL builder for parameterized Postgres-style `INSERT ... ON CONFLICT DO NOTHING` batch upserts.
  """

  alias Trysac.BroadwayIngestPipeline.Error

  @identifier_regex ~r/\A[a-z_][a-z0-9_]{0,62}\z/
  @max_params_per_statement 65_535

  @type statement :: {String.t(), [term()]}

  @doc """
  Builds one or more parameterized `INSERT INTO ... ON CONFLICT (<first_col>) DO NOTHING` statements.

  Splits rows across multiple statements so no single statement exceeds 65,535 parameters.
  Raises `Trysac.BroadwayIngestPipeline.Error` with `:invalid_identifier` if `table` or any
  column name does not match `~r/^[a-z_][a-z0-9_]{0,62}$/`.
  """
  @spec upsert(String.t(), [String.t()], [map()]) :: [statement()]
  def upsert(table, [], rows) when is_binary(table) and is_list(rows) do
    validate_identifier!(table)
    raise Error.new(:invalid_identifier, "columns list must not be empty")
  end

  def upsert(table, [_ | _] = columns, rows) when is_binary(table) and is_list(rows) do
    validate_identifier!(table)
    Enum.each(columns, &validate_identifier!/1)

    if rows == [] do
      []
    else
      generate_upsert_statements(table, columns, rows)
    end
  end

  defp generate_upsert_statements(table, columns, rows) do
    col_count = length(columns)
    max_rows_per_stmt = div(@max_params_per_statement, col_count)
    quoted_table = quote_ident(table)
    quoted_cols = Enum.map_join(columns, ", ", &quote_ident/1)
    conflict_col = quote_ident(hd(columns))
    col_keys = Enum.map(columns, &{&1, safe_to_atom(&1)})

    rows
    |> Enum.chunk_every(max_rows_per_stmt)
    |> Enum.map(fn chunk ->
      build_statement(quoted_table, quoted_cols, conflict_col, col_keys, col_count, chunk)
    end)
  end

  defp safe_to_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp validate_identifier!(ident) when is_binary(ident) do
    if not Regex.match?(@identifier_regex, ident) do
      raise Error.new(
              :invalid_identifier,
              "invalid SQL identifier: #{Error.snippet(ident)}"
            )
    end
  end

  defp validate_identifier!(ident) do
    raise Error.new(
            :invalid_identifier,
            "invalid SQL identifier: #{Error.snippet(ident)}"
          )
  end

  defp quote_ident(ident), do: "\"#{ident}\""

  defp build_statement(quoted_table, quoted_cols, conflict_col, col_keys, col_count, chunk) do
    {tuples_rev, params_rev, _} =
      Enum.reduce(chunk, {[], [], 1}, fn row, {t_acc, p_acc, start_idx} ->
        placeholders =
          Enum.map_join(0..(col_count - 1), ", ", fn offset -> "$#{start_idx + offset}" end)

        tuple_sql = "(#{placeholders})"

        p_next =
          Enum.reduce(col_keys, p_acc, fn {str_key, atom_key}, acc ->
            val = fetch_col(row, str_key, atom_key)
            [val | acc]
          end)

        {[tuple_sql | t_acc], p_next, start_idx + col_count}
      end)

    values_sql = tuples_rev |> Enum.reverse() |> Enum.join(", ")

    sql =
      "INSERT INTO #{quoted_table} (#{quoted_cols}) VALUES #{values_sql} ON CONFLICT (#{conflict_col}) DO NOTHING"

    {sql, Enum.reverse(params_rev)}
  end

  defp fetch_col(row, str_key, atom_key) when is_map(row) do
    cond do
      Map.has_key?(row, str_key) -> Map.get(row, str_key)
      atom_key != nil and Map.has_key?(row, atom_key) -> Map.get(row, atom_key)
      true -> nil
    end
  end
end
