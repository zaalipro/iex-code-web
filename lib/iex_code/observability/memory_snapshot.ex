defmodule IexCode.Observability.MemorySnapshot do
  @moduledoc """
  Immutable data structure representing a point-in-time telemetry sample of
  physical OS memory, BEAM VM allocators, process concurrency, and micro-GC activity.
  """

  @enforce_keys [
    :rss_bytes,
    :beam_total_bytes,
    :beam_processes_bytes,
    :beam_system_bytes,
    :beam_atom_bytes,
    :beam_binary_bytes,
    :beam_ets_bytes,
    :process_count,
    :gc_runs,
    :gc_words_reclaimed,
    :delta_gc_runs,
    :delta_reclaimed_bytes,
    :timestamp
  ]
  defstruct [
    :rss_bytes,
    :beam_total_bytes,
    :beam_processes_bytes,
    :beam_system_bytes,
    :beam_atom_bytes,
    :beam_binary_bytes,
    :beam_ets_bytes,
    :process_count,
    :gc_runs,
    :gc_words_reclaimed,
    :delta_gc_runs,
    :delta_reclaimed_bytes,
    :timestamp
  ]

  @type t :: %__MODULE__{
          rss_bytes: non_neg_integer(),
          beam_total_bytes: non_neg_integer(),
          beam_processes_bytes: non_neg_integer(),
          beam_system_bytes: non_neg_integer(),
          beam_atom_bytes: non_neg_integer(),
          beam_binary_bytes: non_neg_integer(),
          beam_ets_bytes: non_neg_integer(),
          process_count: non_neg_integer(),
          gc_runs: non_neg_integer(),
          gc_words_reclaimed: non_neg_integer(),
          delta_gc_runs: non_neg_integer(),
          delta_reclaimed_bytes: non_neg_integer(),
          timestamp: DateTime.t() | nil
        }

  @doc """
  Constructs a new `%MemorySnapshot{}` with sensible defaults for missing fields.
  """
  def new(attrs \\ %{}) do
    attrs_map = Map.new(attrs)

    %__MODULE__{
      rss_bytes: Map.get(attrs_map, :rss_bytes, 0),
      beam_total_bytes: Map.get(attrs_map, :beam_total_bytes, 0),
      beam_processes_bytes: Map.get(attrs_map, :beam_processes_bytes, 0),
      beam_system_bytes: Map.get(attrs_map, :beam_system_bytes, 0),
      beam_atom_bytes: Map.get(attrs_map, :beam_atom_bytes, 0),
      beam_binary_bytes: Map.get(attrs_map, :beam_binary_bytes, 0),
      beam_ets_bytes: Map.get(attrs_map, :beam_ets_bytes, 0),
      process_count: Map.get(attrs_map, :process_count, 0),
      gc_runs: Map.get(attrs_map, :gc_runs, 0),
      gc_words_reclaimed: Map.get(attrs_map, :gc_words_reclaimed, 0),
      delta_gc_runs: Map.get(attrs_map, :delta_gc_runs, 0),
      delta_reclaimed_bytes: Map.get(attrs_map, :delta_reclaimed_bytes, 0),
      timestamp: Map.get(attrs_map, :timestamp, DateTime.utc_now())
    }
  end

  @doc """
  Formats an integer byte count into a concise, human-readable string (KB, MB, GB).

  ## Examples

      iex> MemorySnapshot.format_bytes(1024)
      "1.0 KB"

      iex> MemorySnapshot.format_bytes(71_512_883)
      "68.2 MB"

      iex> MemorySnapshot.format_bytes(0)
      "0 B"
  """
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    "#{bytes} B"
  end

  def format_bytes(bytes) when is_float(bytes) do
    format_bytes(round(bytes))
  end

  def format_bytes(_), do: "0 B"
end
