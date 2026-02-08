defmodule Projection.RouterTest do
  use ExUnit.Case, async: true

  alias Projection.TestRouter, as: Router

  test "resolve returns known routes and rejects unknown routes" do
    assert {:ok, route} = Router.resolve("clock")
    assert route.screen_module == Projection.TestScreens.Clock
    assert {:error, :unknown_route} = Router.resolve("missing")
  end

  test "navigate pushes onto stack and back pops stack" do
    assert {:ok, nav} = Router.initial_nav("clock", %{"clock_text" => "10:42:17"})
    assert Router.current(nav).name == "clock"
    assert length(nav.stack) == 1

    assert {:ok, nav} = Router.navigate(nav, "devices", %{"count" => 5})
    assert Router.current(nav).name == "devices"
    assert Router.current(nav).params == %{"count" => 5}
    assert length(nav.stack) == 2

    assert {:ok, nav} = Router.back(nav)
    assert Router.current(nav).name == "clock"
    assert length(nav.stack) == 1
  end

  test "screen_session boundary detection matches route metadata" do
    assert {:ok, nav} = Router.initial_nav("clock", %{})
    assert {:ok, false} = Router.screen_session_transition?(nav, "devices")
    assert {:ok, true} = Router.screen_session_transition?(nav, "admin")
  end

  test "compile-time route helpers expose centralized names and paths" do
    assert Router.route_keys() == [:clock, :devices, :admin]
    assert Router.route_names() == ["clock", "devices", "admin"]
    assert Router.route_name(:clock) == "clock"
    assert Router.route_path(:devices) == "/devices"

    assert_raise ArgumentError, ~r/unknown route key/, fn ->
      Router.route_name(:missing)
    end
  end
end
