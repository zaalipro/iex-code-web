defmodule IexCode.Research.URLGuardTest do
  use ExUnit.Case, async: true

  alias IexCode.Research.URLGuard

  test "accepts an HTTP URL only when every DNS answer is public" do
    resolver = fn "example.test" ->
      {:ok, [{93, 184, 216, 34}, {0x2606, 0x2800, 0x220, 1, 0, 0, 0, 0x248}]}
    end

    assert {:ok, %{uri: uri, address: {93, 184, 216, 34}}} =
             URLGuard.validate_and_resolve("HTTPS://Example.Test./path#fragment",
               resolver: resolver
             )

    assert uri.scheme == "https"
    assert uri.host == "example.test"
    assert uri.fragment == nil
  end

  test "rejects dangerous syntax before resolution" do
    resolver = fn _ -> flunk("resolver must not be called") end

    assert {:error, :unsupported_scheme} =
             URLGuard.validate_and_resolve("file:///etc/passwd", resolver: resolver)

    assert {:error, :credentials_not_allowed} =
             URLGuard.validate_and_resolve("https://user:secret@example.test/",
               resolver: resolver
             )

    assert {:error, :localhost_not_allowed} =
             URLGuard.validate_and_resolve("http://api.localhost/", resolver: resolver)

    assert {:error, :invalid_host} =
             URLGuard.validate_and_resolve("http://[fe80::1%25en0]/", resolver: resolver)
  end

  test "rejects literal and DNS-returned non-public addresses" do
    assert {:error, :non_public_address} = URLGuard.validate_and_resolve("http://127.0.0.1/")
    assert {:error, :non_public_address} = URLGuard.validate_and_resolve("http://[::1]/")
    assert {:error, :non_public_address} = URLGuard.validate_and_resolve("http://[fc00::1]/")
    assert {:error, :non_public_address} = URLGuard.validate_and_resolve("http://[ff02::1]/")

    resolver = fn _ -> {:ok, [{93, 184, 216, 34}, {169, 254, 169, 254}]} end

    assert {:error, :non_public_address} =
             URLGuard.validate_and_resolve("https://mixed.test", resolver: resolver)
  end

  test "classifies special and globally routed ranges" do
    rejected = [
      {0, 0, 0, 0},
      {10, 1, 2, 3},
      {100, 64, 1, 1},
      {172, 31, 255, 1},
      {192, 168, 1, 1},
      {192, 0, 2, 1},
      {198, 18, 0, 1},
      {203, 0, 113, 1},
      {224, 0, 0, 1},
      {255, 255, 255, 255},
      {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1},
      {0x2002, 0, 0, 0, 0, 0, 0, 1},
      {0x4000, 0, 0, 0, 0, 0, 0, 1}
    ]

    refute Enum.any?(rejected, &URLGuard.public_address?/1)
    assert URLGuard.public_address?({1, 1, 1, 1})
    assert URLGuard.public_address?({0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111})
  end
end
