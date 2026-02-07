defmodule Projection.StateChangeTrackingTest do
  use ExUnit.Case, async: true

  alias ProjectionUI.State

  test "assign tracks changed fields only when value differs" do
    state = State.new(%{count: 1})

    unchanged_state = State.assign(state, :count, 1)
    assert State.changed_fields(unchanged_state) == []

    changed_state = State.assign(unchanged_state, :count, 2)
    assert State.changed_fields(changed_state) == [:count]
  end

  test "update marks changed and clear_changed resets tracking" do
    state =
      State.new(%{count: 1})
      |> State.update(:count, &(&1 + 1))
      |> State.assign(:title, "Projection")

    assert State.changed_fields(state) == [:count, :title]

    cleared = State.clear_changed(state)
    assert State.changed_fields(cleared) == []
    assert cleared.assigns == %{count: 2, title: "Projection"}
  end
end
