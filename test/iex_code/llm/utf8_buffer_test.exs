defmodule IexCode.LLM.UTF8BufferTest do
  use ExUnit.Case, async: false
  alias IexCode.LLM.UTF8Buffer

  describe "process_bytes/2" do
    test "processes 1-byte ASCII binary without splitting" do
      acc = UTF8Buffer.new()
      {valid, rest} = UTF8Buffer.process_bytes(acc, "hello world 123!")
      assert valid == "hello world 123!"
      assert rest == <<>>
    end

    test "handles 2-byte UTF-8 character split across chunks" do
      # "é" is <<195, 169>>
      acc = UTF8Buffer.new()

      # Chunk 1: "Caf" + first byte of é (195)
      {valid1, rest1} = UTF8Buffer.process_bytes(acc, "Caf" <> <<195>>)
      assert valid1 == "Caf"
      assert rest1 == <<195>>

      # Chunk 2: second byte of é (169) + " latte"
      {valid2, rest2} = UTF8Buffer.process_bytes(rest1, <<169>> <> " latte")
      assert valid2 == "é latte"
      assert rest2 == <<>>
    end

    test "handles 3-byte UTF-8 character split across chunks" do
      # "日" is <<230, 151, 165>>
      acc = UTF8Buffer.new()

      # Chunk 1: first 2 bytes
      {valid1, rest1} = UTF8Buffer.process_bytes(acc, "Day: " <> <<230, 151>>)
      assert valid1 == "Day: "
      assert rest1 == <<230, 151>>

      # Chunk 2: 3rd byte + text
      {valid2, rest2} = UTF8Buffer.process_bytes(rest1, <<165>> <> " (Sunday)")
      assert valid2 == "日 (Sunday)"
      assert rest2 == <<>>
    end

    test "handles 4-byte UTF-8 emoji split across 3 chunks" do
      # 🐝 is <<240, 159, 144, 157>>
      acc = UTF8Buffer.new()

      # Chunk 1: byte 1
      {valid1, rest1} = UTF8Buffer.process_bytes(acc, "Emoji: " <> <<240>>)
      assert valid1 == "Emoji: "
      assert rest1 == <<240>>

      # Chunk 2: bytes 2 and 3
      {valid2, rest2} = UTF8Buffer.process_bytes(rest1, <<159, 144>>)
      assert valid2 == ""
      assert rest2 == <<240, 159, 144>>

      # Chunk 3: byte 4 + end of text
      {valid3, rest3} = UTF8Buffer.process_bytes(rest2, <<157>> <> " Buzzing")
      assert valid3 == "🐝 Buzzing"
      assert rest3 == <<>>
    end

    test "recovers from corrupt byte sequence without crashing" do
      acc = UTF8Buffer.new()
      # Invalid leading byte 0xFF followed by valid text
      {valid, rest} = UTF8Buffer.process_bytes(acc, <<255>> <> "Hello")
      assert valid == "\uFFFDHello"
      assert rest == <<>>
    end
  end

  describe "flush/1" do
    test "flushes clean buffer" do
      assert {"", <<>>} = UTF8Buffer.flush(<<>>)
    end

    test "flushes valid UTF8 buffer" do
      assert {"completed", <<>>} = UTF8Buffer.flush("completed")
    end

    test "sanitizes incomplete bytes on flush" do
      {flushed, <<>>} = UTF8Buffer.flush(<<240, 159>>)
      assert String.contains?(flushed, "\uFFFD")
    end
  end
end
