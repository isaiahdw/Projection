defmodule Projection.ProtocolTest do
  use ExUnit.Case, async: true

  alias Projection.Protocol

  @contract_path Path.expand("../../priv/protocol_contract/contract.json", __DIR__)

  defp load_contract_fixture do
    @contract_path
    |> File.read!()
    |> Jason.decode!()
  end

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

  test "contract fixture aligns caps, envelope semantics, and framing sample" do
    fixture = load_contract_fixture()
    caps = fixture["caps"]

    assert Protocol.ui_to_elixir_cap() == caps["ui_to_elixir"]
    assert Protocol.elixir_to_ui_cap() == caps["elixir_to_ui"]

    assert {:ok, %{"t" => "ready", "sid" => "S1"}} =
             fixture["ui_ready"] |> Jason.encode!() |> Protocol.decode_inbound()

    assert {:ok, %{"t" => "intent", "name" => "ui.route.navigate", "id" => 7}} =
             fixture["ui_intent"] |> Jason.encode!() |> Protocol.decode_inbound()

    render = Protocol.render_envelope("S1", 1, %{"clock_text" => "10:42:17"})
    assert {:ok, render_json} = Protocol.encode_outbound(render)
    assert Jason.decode!(render_json) == fixture["elixir_render"]

    patch =
      Protocol.patch_envelope(
        "S1",
        2,
        [
          %{"op" => "replace", "path" => "/clock_text", "value" => "10:42:18"}
        ], ack: 7)

    assert {:ok, patch_json} = Protocol.encode_outbound(patch)
    assert Jason.decode!(patch_json) == fixture["elixir_patch"]

    error = Protocol.error_envelope("S1", 2, "decode_error", "malformed inbound json")
    assert {:ok, error_json} = Protocol.encode_outbound(error)
    assert Jason.decode!(error_json) == fixture["elixir_error"]

    frame_hex = fixture["frame_sample"]["frame_hex"]
    payload_ascii = fixture["frame_sample"]["payload_ascii"]
    frame = Base.decode16!(String.upcase(frame_hex))
    <<len::unsigned-big-32, payload::binary>> = frame
    assert len == byte_size(payload_ascii)
    assert payload == payload_ascii
  end
end
