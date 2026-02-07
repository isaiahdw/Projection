defmodule Projection.ProtocolTest do
  use ExUnit.Case, async: true

  alias Projection.Protocol

  test "decodes ready envelope" do
    payload = ~s({"t":"ready","sid":"S1","capabilities":{"m1":true}})

    assert {:ok, %{"t" => "ready", "sid" => "S1"}} = Protocol.decode_inbound(payload)
  end

  test "rejects oversized inbound frame" do
    payload = String.duplicate("a", Protocol.ui_to_elixir_cap() + 1)
    assert {:error, :frame_too_large} = Protocol.decode_inbound(payload)
  end

  test "encodes render envelope under outbound cap" do
    envelope = Protocol.render_envelope("S1", 1, %{clock_text: "10:42:17"})
    assert {:ok, encoded} = Protocol.encode_outbound(envelope)
    assert is_binary(encoded)
  end

  test "encodes patch envelope under outbound cap" do
    envelope =
      Protocol.patch_envelope("S1", 2, [
        %{"op" => "replace", "path" => "/clock_text", "value" => "10:42:18"}
      ])

    assert {:ok, encoded} = Protocol.encode_outbound(envelope)
    assert is_binary(encoded)
  end

  test "rejects malformed inbound payload" do
    assert {:error, :decode_error} = Protocol.decode_inbound("{")
  end
end
