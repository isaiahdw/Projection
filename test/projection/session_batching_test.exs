defmodule Projection.SessionBatchingTest do
  use ExUnit.Case, async: true

  alias Projection.Session

  test "coalesces duplicate paths into one patch and keeps latest ack" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           port_owner: self(),
           batch_window_ms: 80,
           max_pending_ops: 64
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 101,
               "name" => "clock.pause",
               "payload" => %{}
             })

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 102,
               "name" => "clock.resume",
               "payload" => %{}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 500
    assert patch["t"] == "patch"
    assert patch["sid"] == "S1"
    assert patch["rev"] == 2
    assert patch["ack"] == 102
    assert [%{"op" => "replace", "path" => "/clock_running", "value" => true}] = patch["ops"]

    refute_receive {:"$gen_cast", {:send_envelope, _}}, 200
  end

  test "flushes immediately when pending op limit is reached" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           port_owner: self(),
           batch_window_ms: 250,
           max_pending_ops: 1
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 201,
               "name" => "clock.pause",
               "payload" => %{}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch_1}}, 300
    assert patch_1["rev"] == 2
    assert patch_1["ack"] == 201

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 202,
               "name" => "clock.resume",
               "payload" => %{}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch_2}}, 300
    assert patch_2["rev"] == 3
    assert patch_2["ack"] == 202
  end

  test "high-rate commits collapse to latest value with monotonic revision" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           port_owner: self(),
           batch_window_ms: 120,
           max_pending_ops: 64
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    Enum.each(1..20, fn id ->
      assert {:ok, []} =
               Session.handle_ui_envelope_sync(session, %{
                 "t" => "intent",
                 "sid" => "S1",
                 "id" => id,
                 "name" => "clock.commit_label",
                 "payload" => %{"arg" => "Label #{id}"}
               })
    end)

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 800
    assert patch["t"] == "patch"
    assert patch["sid"] == "S1"
    assert patch["rev"] == 2
    assert patch["ack"] == 20

    assert [%{"op" => "replace", "path" => "/clock_label", "value" => "Label 20"}] = patch["ops"]

    refute_receive {:"$gen_cast", {:send_envelope, _}}, 250
  end
end
