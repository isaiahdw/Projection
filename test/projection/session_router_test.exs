defmodule Projection.SessionRouterTest do
  use ExUnit.Case, async: true

  alias Projection.Session

  test "routed mode renders nav and screen VM and supports navigate/back intents" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           router: Projection.Router,
           route: "clock",
           screen_params: %{"clock_text" => "10:42:17"},
           port_owner: self()
         ]}
      )

    assert {:ok, [render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert render["vm"][:screen][:name] == "clock"
    assert render["vm"][:screen][:vm][:clock_text] == "10:42:17"
    assert render["vm"][:nav][:current][:name] == "clock"
    assert length(render["vm"][:nav][:stack]) == 1

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 10,
               "name" => "ui.route.navigate",
               "payload" => %{"to" => "devices", "params" => %{"count" => 2}}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch_to_devices}}, 200
    assert patch_to_devices["t"] == "patch"
    assert patch_to_devices["ack"] == 10

    snapshot = Session.snapshot(session)
    assert snapshot.screen_module == ProjectionUI.Screens.Devices
    assert snapshot.vm.screen.name == "devices"
    assert snapshot.vm.nav.current.name == "devices"
    assert length(snapshot.vm.screen.vm.devices.order) == 2

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 11,
               "name" => "ui.back",
               "payload" => %{}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch_to_clock}}, 200
    assert patch_to_clock["t"] == "patch"
    assert patch_to_clock["ack"] == 11

    snapshot = Session.snapshot(session)
    assert snapshot.screen_module == ProjectionUI.Screens.Clock
    assert snapshot.vm.screen.name == "clock"
    assert snapshot.vm.nav.current.name == "clock"
    assert length(snapshot.vm.nav.stack) == 1
  end

  test "ui.route.patch updates current screen params through handle_params/2" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           router: Projection.Router,
           route: "clock",
           screen_params: %{"clock_text" => "10:42:17"},
           port_owner: self()
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 12,
               "name" => "ui.route.patch",
               "payload" => %{"params" => %{"clock_text" => "11:11:11"}}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 200
    assert patch["t"] == "patch"
    assert patch["ack"] == 12

    assert Enum.any?(patch["ops"], fn op ->
             op["op"] == "replace" and op["path"] == "/screen/vm/clock_text" and
               op["value"] == "11:11:11"
           end)

    snapshot = Session.snapshot(session)
    assert snapshot.vm.screen.vm.clock_text == "11:11:11"
  end

  test "cross screen_session navigation is rejected" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           router: Projection.Router,
           route: "clock",
           port_owner: self()
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 13,
               "name" => "ui.route.navigate",
               "payload" => %{"to" => "admin", "params" => %{}}
             })

    refute_receive {:"$gen_cast", {:send_envelope, _patch}}, 100

    snapshot = Session.snapshot(session)
    assert snapshot.vm.screen.name == "clock"
  end

  test "ui.route.navigate accepts arg shorthand route name" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           router: Projection.Router,
           route: "clock",
           port_owner: self()
         ]}
      )

    assert {:ok, [_render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 14,
               "name" => "ui.route.navigate",
               "payload" => %{"arg" => "devices"}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 200
    assert patch["t"] == "patch"
    assert patch["ack"] == 14

    snapshot = Session.snapshot(session)
    assert snapshot.vm.screen.name == "devices"
  end

  test "route transitions sync subscriptions by active screen" do
    owner = self()
    subscription_hook = fn action, topic -> send(owner, {:subscription, action, topic}) end

    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           router: Projection.Router,
           route: "clock",
           screen_params: %{"clock_timezone" => "UTC"},
           subscription_hook: subscription_hook,
           port_owner: self()
         ]}
      )

    assert_receive {:subscription, :subscribe, "clock.timezone:UTC"}, 200

    assert {:ok, [_render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 20,
               "name" => "ui.route.navigate",
               "payload" => %{"to" => "devices", "params" => %{}}
             })

    assert_receive {:subscription, :unsubscribe, "clock.timezone:UTC"}, 200
    assert_receive {:subscription, :subscribe, "devices"}, 200

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 21,
               "name" => "ui.back",
               "payload" => %{}
             })

    assert_receive {:subscription, :unsubscribe, "devices"}, 200
    assert_receive {:subscription, :subscribe, "clock.timezone:UTC"}, 200
  end

  test "ui.route.patch updates route-driven subscriptions" do
    owner = self()
    subscription_hook = fn action, topic -> send(owner, {:subscription, action, topic}) end

    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           router: Projection.Router,
           route: "clock",
           screen_params: %{"clock_timezone" => "UTC"},
           subscription_hook: subscription_hook,
           port_owner: self()
         ]}
      )

    assert_receive {:subscription, :subscribe, "clock.timezone:UTC"}, 200

    assert {:ok, [_render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 22,
               "name" => "ui.route.patch",
               "payload" => %{"params" => %{"clock_timezone" => "America/Chicago"}}
             })

    assert_receive {:subscription, :unsubscribe, "clock.timezone:UTC"}, 200
    assert_receive {:subscription, :subscribe, "clock.timezone:America/Chicago"}, 200
  end
end
