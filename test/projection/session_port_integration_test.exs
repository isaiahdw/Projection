defmodule Projection.SessionPortIntegrationTest do
  use ExUnit.Case, async: true

  alias Projection.Session

  test "ready triggers render and keeps stable sid with monotonic rev" do
    {:ok, session} = start_supervised({Session, [screen_params: %{"clock_text" => "10:42:17"}]})

    assert {:ok, [render_1]} =
             Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})

    assert render_1["t"] == "render"
    assert render_1["sid"] == "S1"
    assert render_1["rev"] == 1
    assert render_1["vm"][:clock_text] == "10:42:17"

    # A reconnect-ready with a different sid keeps the session sid stable.
    assert {:ok, [render_2]} =
             Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S2"})

    assert render_2["sid"] == "S1"
    assert render_2["rev"] == 2

    snapshot = Session.snapshot(session)
    assert snapshot.sid == "S1"
    assert snapshot.rev == 2
  end

  test "tick emits one replace patch for /clock_text" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_params: %{"clock_text" => "10:42:17"},
           tick_ms: 5_000,
           port_owner: self()
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})

    send(session, :tick)

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 200
    assert patch["t"] == "patch"
    assert patch["sid"] == "S1"
    assert patch["rev"] == 2

    assert [%{"op" => "replace", "path" => "/clock_text", "value" => clock_text}] = patch["ops"]
    assert is_binary(clock_text)

    snapshot = Session.snapshot(session)
    assert snapshot.rev == 2
    assert snapshot.vm.clock_text == clock_text
  end

  test "pause stops tick updates and resume allows tick updates again" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_params: %{"clock_text" => "10:42:17"},
           tick_ms: 5_000,
           port_owner: self()
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 1,
               "name" => "clock.pause",
               "payload" => %{}
             })

    assert_receive {:"$gen_cast", {:send_envelope, pause_patch}}, 200
    assert pause_patch["t"] == "patch"
    assert pause_patch["sid"] == "S1"
    assert pause_patch["rev"] == 2

    assert Enum.any?(pause_patch["ops"], fn op ->
             op["op"] == "replace" and op["path"] == "/clock_running" and op["value"] == false
           end)

    send(session, :tick)
    refute_receive {:"$gen_cast", {:send_envelope, _}}, 100

    assert {:ok, []} =
             Session.handle_ui_envelope(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 2,
               "name" => "clock.resume",
               "payload" => %{}
             })

    assert_receive {:"$gen_cast", {:send_envelope, resume_patch}}, 200
    assert resume_patch["t"] == "patch"
    assert resume_patch["sid"] == "S1"
    assert resume_patch["rev"] == 3

    assert Enum.any?(resume_patch["ops"], fn op ->
             op["op"] == "replace" and op["path"] == "/clock_running" and op["value"] == true
           end)

    send(session, :tick)
    assert_receive {:"$gen_cast", {:send_envelope, tick_patch}}, 200
    assert tick_patch["t"] == "patch"
    assert tick_patch["sid"] == "S1"
    assert tick_patch["rev"] == 4

    assert Enum.any?(tick_patch["ops"], fn op ->
             op["op"] == "replace" and op["path"] == "/clock_text" and is_binary(op["value"])
           end)
  end

  test "timezone selection updates clock timezone and clock text" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_params: %{"clock_text" => "10:42:17"},
           tick_ms: 5_000,
           port_owner: self()
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 3,
               "name" => "clock.set_timezone",
               "payload" => %{"timezone" => "America/Los_Angeles"}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 200
    assert patch["t"] == "patch"
    assert patch["sid"] == "S1"
    assert patch["rev"] == 2

    assert Enum.any?(patch["ops"], fn op ->
             op["op"] == "replace" and op["path"] == "/clock_timezone" and
               op["value"] == "America/Los_Angeles"
           end)

    assert Enum.any?(patch["ops"], fn op ->
             op["op"] == "replace" and op["path"] == "/clock_text" and is_binary(op["value"])
           end)
  end

  test "timezone selection accepts generic intent arg field" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_params: %{"clock_text" => "10:42:17"},
           tick_ms: 5_000,
           port_owner: self()
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 4,
               "name" => "clock.set_timezone",
               "payload" => %{"arg" => "America/New_York"}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 200
    assert patch["t"] == "patch"
    assert patch["sid"] == "S1"
    assert patch["rev"] == 2

    assert Enum.any?(patch["ops"], fn op ->
             op["op"] == "replace" and op["path"] == "/clock_timezone" and
               op["value"] == "America/New_York"
           end)
  end

  test "unknown screen intent is ignored when no state changes occur" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           port_owner: self()
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 5,
               "name" => "clock.typo",
               "payload" => %{}
             })
  end

  test "devices screen ignores fabricated ids without crashing or patching" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_module: ProjectionUI.Screens.Devices,
           port_owner: self()
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 6,
               "name" => "set_status",
               "payload" => %{"id" => "dev-99999", "status_text" => "Offline"}
             })

    refute_receive {:"$gen_cast", {:send_envelope, _}}, 100
  end
end
