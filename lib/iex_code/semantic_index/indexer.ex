defmodule IexCode.SemanticIndex.Indexer do
  @moduledoc """
  Incremental semantic codebase indexer and sub-second in-memory vector search engine.
  Features:
  - Incremental SHA-256 change detection: only embeds new or modified files.
  - SQLite persistence via `code_embeddings` table.
  - In-memory ETS cache (`:iex_code_semantic_cache`) for sub-10ms similarity queries.
  - Pure BEAM IEEE 754 packed float32 dot product ranking.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias IexCode.Repo
  alias IexCode.SemanticIndex.Chunker
  alias IexCode.SemanticIndex.CodeEmbedding
  alias IexCode.SemanticIndex.EmbeddingClient
  alias IexCode.SemanticIndex.Vector

  @table_name :iex_code_semantic_cache
  @excluded_dirs [
    "_build",
    "deps",
    ".git",
    ".agents",
    "tmp",
    "node_modules",
    "priv/static"
  ]
  @allowed_extensions [
    ".ex",
    ".exs",
    ".heex",
    ".md",
    ".json",
    ".js",
    ".ts",
    ".css",
    ".html",
    ".yml",
    ".yaml"
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Ensures ETS table is created and returns its name.
  """
  def table_name, do: @table_name

  @doc """
  Indexes a project workspace incrementally.
  """
  def index_project(project_id, root_path, opts \\ []) do
    GenServer.call(__MODULE__, {:index_project, project_id, root_path, opts}, 120_000)
  end

  @doc """
  Performs sub-second ranked vector similarity search across indexed code chunks.
  """
  @spec search(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(project_id, query, opts \\ []) when is_binary(project_id) and is_binary(query) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.4)
    path_filter = Keyword.get(opts, :path)

    case EmbeddingClient.embed(query, Keyword.put(opts, :return, :binary)) do
      {:ok, [query_vector | _]} ->
        ensure_table()
        results = search_in_memory(project_id, query_vector, threshold, path_filter, limit)
        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Warms up in-memory ETS cache from SQLite for a given project.
  """
  def warm_cache(project_id) do
    GenServer.call(__MODULE__, {:warm_cache, project_id}, 30_000)
  end

  @doc """
  Returns indexed chunk stats for a project.
  """
  def stats(project_id) do
    ensure_table()

    ets_count =
      :ets.select_count(@table_name, [
        {{:_, project_id, :_, :_, :_, :_, :_, :_, :_}, [], [true]}
      ])

    db_count =
      Repo.one(
        from(e in CodeEmbedding,
          where: e.project_id == ^project_id,
          select: count(e.id)
        )
      ) || 0

    %{ets_chunks: ets_count, db_chunks: db_count}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_init_arg) do
    ensure_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:index_project, project_id, root_path, opts}, _from, state) do
    result = do_index_project(project_id, root_path, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:warm_cache, project_id}, _from, state) do
    count = do_warm_cache(project_id)
    {:reply, {:ok, count}, state}
  end

  # ============================================================================
  # Indexing Engine
  # ============================================================================

  defp do_index_project(project_id, root_path, opts) do
    files = list_indexable_files(root_path)

    # Fetch existing file hashes for this project
    existing_hashes =
      Repo.all(
        from(e in CodeEmbedding,
          where: e.project_id == ^project_id,
          select: {e.file_path, e.file_hash},
          distinct: true
        )
      )
      |> Map.new()

    model = Keyword.get(opts, :model, "nomic-embed-text")
    dimensions = EmbeddingClient.model_dimension(model)

    results =
      Enum.reduce(files, %{indexed: 0, chunks: 0, skipped: 0}, fn rel_path, acc ->
        full_path = Path.join(root_path, rel_path)

        case File.read(full_path) do
          {:ok, content} ->
            file_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

            if Map.get(existing_hashes, rel_path) == file_hash do
              # Ensure chunks are loaded into ETS cache even if skipped in DB
              ensure_cached(project_id, rel_path)
              %{acc | skipped: acc.skipped + 1}
            else
              # Delete old entries
              delete_file_entries(project_id, rel_path)

              # Generate new chunks
              chunks = Chunker.chunk_file(rel_path, content)

              if chunks == [] do
                acc
              else
                # Batch embed chunks
                chunk_texts = Enum.map(chunks, & &1.content)

                embed_opts =
                  opts
                  |> Keyword.put(:model, model)
                  |> Keyword.put(:return, :binary)

                case EmbeddingClient.embed(chunk_texts, embed_opts) do
                  {:ok, vectors} ->
                    new_count =
                      Enum.zip(chunks, vectors)
                      |> Enum.map(fn {chunk, vector} ->
                        now = DateTime.utc_now() |> DateTime.truncate(:second)

                        attrs = %{
                          id: Ecto.UUID.generate(),
                          project_id: project_id,
                          file_path: rel_path,
                          file_hash: file_hash,
                          chunk_index: chunk.chunk_index,
                          chunk_type: chunk.chunk_type,
                          symbol_name: chunk.symbol_name,
                          symbol_type: chunk.symbol_type,
                          start_line: chunk.start_line,
                          end_line: chunk.end_line,
                          content: chunk.content,
                          embedding: vector,
                          dimensions: dimensions,
                          model: model,
                          inserted_at: now,
                          updated_at: now
                        }

                        # Insert into SQLite
                        %CodeEmbedding{}
                        |> CodeEmbedding.changeset(attrs)
                        |> Repo.insert!()

                        # Insert into ETS
                        :ets.insert(
                          @table_name,
                          {
                            attrs.id,
                            project_id,
                            rel_path,
                            chunk.start_line,
                            chunk.end_line,
                            chunk.symbol_name,
                            chunk.symbol_type,
                            chunk.content,
                            vector
                          }
                        )
                      end)
                      |> length()

                    %{acc | indexed: acc.indexed + 1, chunks: acc.chunks + new_count}

                  {:error, reason} ->
                    Logger.warning("Failed to embed #{rel_path}: #{inspect(reason)}")
                    acc
                end
              end
            end

          _ ->
            acc
        end
      end)

    # Prune files that no longer exist
    prune_deleted_files(project_id, Map.keys(existing_hashes) -- files)

    {:ok, results}
  end

  defp search_in_memory(project_id, query_vector, threshold, path_filter, limit) do
    # Select all chunks for this project from ETS
    entries =
      :ets.select(@table_name, [
        {
          {:"$1", project_id, :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"},
          [],
          [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8"}}]
        }
      ])

    entries
    |> Enum.filter(fn {_id, path, _start, _end, _name, _type, _content, _vec} ->
      is_nil(path_filter) or String.starts_with?(path, path_filter)
    end)
    |> Enum.map(fn {id, path, start_l, end_l, sym_name, sym_type, content, vec} ->
      score = Vector.dot_product(query_vector, vec)

      %{
        id: id,
        file_path: path,
        start_line: start_l,
        end_line: end_l,
        symbol_name: sym_name,
        symbol_type: sym_type,
        content: content,
        score: Float.round(score, 4),
        match_percent: round(max(0.0, score) * 100)
      }
    end)
    |> Enum.filter(&(&1.score >= threshold))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp do_warm_cache(project_id) do
    ensure_table()

    embeddings =
      Repo.all(
        from(e in CodeEmbedding,
          where: e.project_id == ^project_id
        )
      )

    Enum.each(embeddings, fn e ->
      :ets.insert(
        @table_name,
        {
          e.id,
          e.project_id,
          e.file_path,
          e.start_line,
          e.end_line,
          e.symbol_name,
          e.symbol_type,
          e.content,
          e.embedding
        }
      )
    end)

    length(embeddings)
  end

  defp ensure_cached(project_id, file_path) do
    exists? =
      :ets.match(@table_name, {:_, project_id, file_path, :_, :_, :_, :_, :_, :_}, 1) !=
        :"$end_of_table"

    unless exists? do
      embeddings =
        Repo.all(
          from(e in CodeEmbedding,
            where: e.project_id == ^project_id and e.file_path == ^file_path
          )
        )

      Enum.each(embeddings, fn e ->
        :ets.insert(
          @table_name,
          {
            e.id,
            e.project_id,
            e.file_path,
            e.start_line,
            e.end_line,
            e.symbol_name,
            e.symbol_type,
            e.content,
            e.embedding
          }
        )
      end)
    end
  end

  defp delete_file_entries(project_id, file_path) do
    Repo.delete_all(
      from(e in CodeEmbedding,
        where: e.project_id == ^project_id and e.file_path == ^file_path
      )
    )

    :ets.match_delete(@table_name, {:_, project_id, file_path, :_, :_, :_, :_, :_, :_})
  end

  defp prune_deleted_files(project_id, deleted_files) when is_list(deleted_files) do
    Enum.each(deleted_files, fn path ->
      delete_file_entries(project_id, path)
    end)
  end

  defp list_indexable_files(root_path) do
    case File.ls(root_path) do
      {:ok, _} ->
        walk_dir(root_path, "")

      _ ->
        []
    end
  end

  defp walk_dir(root, rel) do
    dir = if rel == "", do: root, else: Path.join(root, rel)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          entry_rel = if rel == "", do: entry, else: Path.join(rel, entry)
          full = Path.join(dir, entry)

          cond do
            entry in @excluded_dirs ->
              []

            File.dir?(full) ->
              walk_dir(root, entry_rel)

            Path.extname(entry) in @allowed_extensions ->
              [entry_rel]

            true ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp ensure_table do
    case :ets.whereis(@table_name) do
      :undefined ->
        try do
          :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> @table_name
        end

      _ ->
        @table_name
    end
  end
end
