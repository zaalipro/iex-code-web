defmodule IexCode.SemanticIndex.Vector do
  @moduledoc """
  High-performance IEEE-754 packed 32-bit float vector arithmetic for pure BEAM execution.
  Stores vectors as compact little-endian binaries (`<<f::float-32-little, ...>>`)
  and calculates dot products and cosine similarity directly over binary streams.
  """

  @doc """
  Packs a list of floats into a binary of 32-bit little-endian floats.
  """
  @spec pack([float() | number()]) :: binary()
  def pack(floats) when is_list(floats) do
    for f <- floats, into: <<>> do
      <<f * 1.0::float-32-little>>
    end
  end

  def pack(binary) when is_binary(binary), do: binary

  @doc """
  Alias for pack/1.
  """
  def to_binary(data), do: pack(data)

  @doc """
  Unpacks a binary of 32-bit little-endian floats into a list of floats.
  """
  @spec unpack(binary() | [float()]) :: [float()]
  def unpack(binary) when is_binary(binary) do
    for <<f::float-32-little <- binary>> do
      f
    end
  end

  def unpack(list) when is_list(list), do: list

  @doc """
  Alias for unpack/1.
  """
  def to_list(data), do: unpack(data)

  @doc """
  Returns the dimension (count of float32 values) of the vector.
  """
  @spec dimension(binary() | [float()]) :: non_neg_integer()
  def dimension(binary) when is_binary(binary) do
    div(byte_size(binary), 4)
  end

  def dimension(list) when is_list(list), do: length(list)

  @doc """
  Calculates the Euclidean (L2) norm of a vector.
  """
  @spec norm(binary() | [float()]) :: float()
  def norm(binary) when is_binary(binary) do
    :math.sqrt(sum_squares(binary, 0.0))
  end

  def norm(list) when is_list(list) do
    norm(pack(list))
  end

  @doc """
  Alias for norm/1.
  """
  def l2_norm(data), do: norm(data)

  defp sum_squares(
         <<f1::float-32-little, f2::float-32-little, f3::float-32-little, f4::float-32-little,
           rest::binary>>,
         acc
       ) do
    sum_squares(rest, acc + f1 * f1 + f2 * f2 + f3 * f3 + f4 * f4)
  end

  defp sum_squares(<<f::float-32-little, rest::binary>>, acc) do
    sum_squares(rest, acc + f * f)
  end

  defp sum_squares(<<>>, acc), do: acc

  @doc """
  L2-normalizes a vector to unit length.
  Accepts packed binary or list of floats, returns packed binary.
  """
  @spec normalize(binary() | [float()]) :: binary()
  def normalize(binary) when is_binary(binary) do
    l2 = norm(binary)

    if l2 > 1.0e-12 do
      inv = 1.0 / l2

      for <<f::float-32-little <- binary>>, into: <<>> do
        <<f * inv::float-32-little>>
      end
    else
      binary
    end
  end

  def normalize(list) when is_list(list) do
    normalize(pack(list))
  end

  @doc """
  Computes the dot product of two packed 32-bit float binaries.
  Runs at native speed without allocating intermediate lists.
  """
  @spec dot_product(binary(), binary()) :: float()
  def dot_product(bin_a, bin_b) when is_binary(bin_a) and is_binary(bin_b) do
    do_dot(bin_a, bin_b, 0.0)
  end

  def dot_product(list_a, list_b) when is_list(list_a) and is_list(list_b) do
    dot_product(pack(list_a), pack(list_b))
  end

  defp do_dot(
         <<a1::float-32-little, a2::float-32-little, a3::float-32-little, a4::float-32-little,
           rest_a::binary>>,
         <<b1::float-32-little, b2::float-32-little, b3::float-32-little, b4::float-32-little,
           rest_b::binary>>,
         acc
       ) do
    do_dot(rest_a, rest_b, acc + a1 * b1 + a2 * b2 + a3 * b3 + a4 * b4)
  end

  defp do_dot(<<a::float-32-little, rest_a::binary>>, <<b::float-32-little, rest_b::binary>>, acc) do
    do_dot(rest_a, rest_b, acc + a * b)
  end

  defp do_dot(<<>>, <<>>, acc), do: acc
  defp do_dot(_, _, acc), do: acc

  @doc """
  Computes Cosine Similarity between two vectors.
  If vectors are already unit-normalized, dot_product is identical to cosine similarity.
  """
  @spec cosine_similarity(binary() | [float()], binary() | [float()]) :: float()
  def cosine_similarity(a, b) do
    norm_a = normalize(if is_binary(a), do: a, else: pack(a))
    norm_b = normalize(if is_binary(b), do: b, else: pack(b))
    dot_product(norm_a, norm_b)
  end
end
