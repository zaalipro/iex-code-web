defmodule IexCode.Research.URLGuard do
  @moduledoc """
  Validates and resolves URLs before the research fetcher makes a connection.

  Resolution is deliberately part of validation: every answer must be globally
  routable. The fetcher then connects to one of the validated addresses rather
  than resolving the hostname a second time, closing the usual DNS-rebinding
  window.
  """

  @type address :: :inet.ip_address()
  @type resolver :: (String.t() -> {:ok, [address()]} | {:error, term()})

  @spec validate_and_resolve(String.t(), keyword()) ::
          {:ok, %{uri: URI.t(), address: address()}} | {:error, term()}
  def validate_and_resolve(url, opts \\ []) when is_binary(url) do
    resolver = Keyword.get(opts, :resolver, &resolve/1)

    with {:ok, uri} <- parse(url),
         {:ok, addresses} <- resolve_host(uri.host, resolver),
         :ok <- public_answers?(addresses) do
      {:ok, %{uri: uri, address: hd(addresses)}}
    end
  end

  @spec public_address?(address()) :: boolean()
  def public_address?({a, b, c, d} = address)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    not ipv4_special?(address)
  end

  def public_address?({a, b, c, d, e, f, g, h} = address)
      when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and d in 0..65_535 and
             e in 0..65_535 and f in 0..65_535 and g in 0..65_535 and h in 0..65_535 do
    not ipv6_special?(address)
  end

  def public_address?(_address), do: false

  defp parse(url) do
    uri = URI.parse(url)
    scheme = uri.scheme && String.downcase(uri.scheme)
    host = uri.host && String.trim_trailing(String.downcase(uri.host), ".")

    cond do
      scheme not in ["http", "https"] ->
        {:error, :unsupported_scheme}

      uri.userinfo != nil ->
        {:error, :credentials_not_allowed}

      is_nil(host) or host == "" ->
        {:error, :missing_host}

      not valid_host_text?(host) or not valid_authority?(uri.authority) ->
        {:error, :invalid_host}

      host == "localhost" or String.ends_with?(host, ".localhost") ->
        {:error, :localhost_not_allowed}

      uri.port not in 1..65_535 ->
        {:error, :invalid_port}

      true ->
        {:ok, %{uri | scheme: scheme, host: host, userinfo: nil, fragment: nil}}
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp valid_host_text?(host) do
    byte_size(host) <= 253 and
      not String.contains?(host, ["%", "\\", "/", "\0", "\r", "\n", "\t", " "])
  end

  defp valid_authority?(authority) when is_binary(authority) do
    not String.contains?(authority, ["%", "\\", "/", "\0", "\r", "\n", "\t", " "])
  end

  defp valid_authority?(_authority), do: false

  defp resolve_host(host, resolver) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, [address]}
      {:error, _} -> call_resolver(resolver, host)
    end
  end

  defp call_resolver(resolver, host) when is_function(resolver, 1) do
    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) and addresses != [] ->
        {:ok, Enum.uniq(addresses)}

      {:ok, []} ->
        {:error, :host_not_found}

      {:error, reason} ->
        {:error, {:dns_error, reason}}

      _ ->
        {:error, :invalid_dns_response}
    end
  rescue
    exception -> {:error, {:dns_error, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:dns_error, {kind, reason}}}
  end

  defp public_answers?(addresses) do
    if Enum.all?(addresses, &public_address?/1),
      do: :ok,
      else: {:error, :non_public_address}
  end

  defp resolve(host) do
    char_host = String.to_charlist(host)

    results =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(char_host, family) do
          {:ok, addresses} -> addresses
          {:error, _} -> []
        end
      end)
      |> Enum.uniq()

    if results == [], do: {:error, :nxdomain}, else: {:ok, results}
  end

  # RFC 6890 special-purpose, private, loopback, link-local, documentation,
  # benchmarking, multicast and reserved IPv4 blocks.
  defp ipv4_special?({a, _, _, _}) when a == 0 or a == 10 or a == 127, do: true
  defp ipv4_special?({100, b, _, _}) when b in 64..127, do: true
  defp ipv4_special?({169, 254, _, _}), do: true
  defp ipv4_special?({172, b, _, _}) when b in 16..31, do: true
  defp ipv4_special?({192, 0, 0, _}), do: true
  defp ipv4_special?({192, 0, 2, _}), do: true
  defp ipv4_special?({192, 31, 196, _}), do: true
  defp ipv4_special?({192, 52, 193, _}), do: true
  defp ipv4_special?({192, 88, 99, _}), do: true
  defp ipv4_special?({192, 168, _, _}), do: true
  defp ipv4_special?({192, 175, 48, _}), do: true
  defp ipv4_special?({198, b, _, _}) when b in 18..19, do: true
  defp ipv4_special?({198, 51, 100, _}), do: true
  defp ipv4_special?({203, 0, 113, _}), do: true
  defp ipv4_special?({a, _, _, _}) when a >= 224, do: true
  defp ipv4_special?(_address), do: false

  # Unspecified/compatible/mapped, discard-only, protocol assignments,
  # documentation, unique-local, link-local and multicast IPv6 ranges.
  defp ipv6_special?({0, _, _, _, _, _, _, _}), do: true
  defp ipv6_special?({0x64, 0xFF9B, _, _, _, _, _, _}), do: true
  defp ipv6_special?({0x100, 0, 0, 0, _, _, _, _}), do: true
  defp ipv6_special?({0x2001, second, _, _, _, _, _, _}) when second <= 0x1FF, do: true
  defp ipv6_special?({0x2001, 0xDB8, _, _, _, _, _, _}), do: true
  defp ipv6_special?({0x2002, _, _, _, _, _, _, _}), do: true
  defp ipv6_special?({0x3FFF, second, _, _, _, _, _, _}) when second <= 0xFFF, do: true
  defp ipv6_special?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp ipv6_special?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true
  defp ipv6_special?({first, _, _, _, _, _, _, _}) when first in 0xFF00..0xFFFF, do: true
  defp ipv6_special?({first, _, _, _, _, _, _, _}) when first in 0x2000..0x3FFF, do: false
  defp ipv6_special?(_address), do: true
end
