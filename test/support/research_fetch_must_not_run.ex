defmodule IexCode.TestResearchFetchMustNotRun do
  @moduledoc false

  def fetch(_url, _opts), do: raise("quick research must not fetch")
end
