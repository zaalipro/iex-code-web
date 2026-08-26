defmodule IexCode.Research.Result do
  @moduledoc """
  Provider-independent search result.

  `metadata` deliberately retains provider-specific fields while the other
  fields give callers a stable shape to rank, render, and cite. When federated
  search providers return the same canonical URL, the first result remains the
  displayed result and `metadata["provenance"]` records every normalized source
  that corroborated it.
  """

  @enforce_keys [:provider, :title, :url]
  defstruct [:provider, :title, :url, :snippet, :published_at, :score, metadata: %{}]

  @type t :: %__MODULE__{
          provider: String.t(),
          title: String.t(),
          url: String.t(),
          snippet: String.t() | nil,
          published_at: String.t() | nil,
          score: number() | nil,
          metadata: map()
        }

  @doc false
  def new(provider, attrs) when (is_atom(provider) or is_binary(provider)) and is_map(attrs) do
    title = value(attrs, :title) |> clean()
    url = value(attrs, :url) |> clean()

    if title && url do
      %__MODULE__{
        provider: to_string(provider),
        title: title,
        url: url,
        snippet: value(attrs, :snippet) |> clean(),
        published_at: value(attrs, :published_at) |> clean(),
        score: normalize_score(value(attrs, :score)),
        metadata: normalize_metadata(value(attrs, :metadata))
      }
    end
  end

  @doc "Merges a duplicate result into the primary result's provenance metadata."
  @spec merge_provenance(t(), t()) :: t()
  def merge_provenance(%__MODULE__{} = primary, %__MODULE__{} = duplicate) do
    provenance =
      primary
      |> provenance()
      |> Kernel.++(provenance(duplicate))
      |> Enum.uniq_by(&{&1["provider"], &1["url"], &1["title"]})

    %{primary | metadata: Map.put(primary.metadata, "provenance", provenance)}
  end

  @doc "Returns normalized provenance entries for a result."
  @spec provenance(t()) :: [map()]
  def provenance(%__MODULE__{} = result) do
    entries =
      result.metadata
      |> Map.get("provenance", Map.get(result.metadata, :provenance))
      |> List.wrap()
      |> Enum.filter(&valid_provenance_entry?/1)

    case entries do
      [] -> [provenance_entry(result)]
      entries -> entries
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp clean(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp clean(_value), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp normalize_score(value) when is_number(value), do: value
  defp normalize_score(_value), do: nil

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp provenance_entry(result) do
    %{
      "provider" => result.provider,
      "title" => result.title,
      "url" => result.url,
      "snippet" => result.snippet,
      "published_at" => result.published_at,
      "score" => result.score
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp valid_provenance_entry?(entry) when is_map(entry) do
    is_binary(Map.get(entry, "provider")) and is_binary(Map.get(entry, "url"))
  end

  defp valid_provenance_entry?(_entry), do: false
end
