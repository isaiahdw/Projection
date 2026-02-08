defmodule ProjectionTest do
  use ExUnit.Case, async: true

  test "starts a session supervisor" do
    {:ok, sup} =
      start_supervised(
        {ProjectionUI.SessionSupervisor, [screen_module: Projection.TestScreens.Clock]}
      )

    assert is_pid(sup)
  end
end
