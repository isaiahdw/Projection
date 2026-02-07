defmodule Projection.SessionScreenControllerTest do
  use ExUnit.Case, async: true

  alias Projection.Session

  defmodule ThermostatScreen do
    use ProjectionUI, :screen

    @impl true
    def mount(_params, session, state) do
      base_temperature = Map.get(session, "base_temperature", 70)
      {:ok, assign(state, :temperature, base_temperature)}
    end

    @impl true
    def handle_event("inc_temperature", _params, state) do
      {:noreply, update(state, :temperature, &((&1 || 0) + 1))}
    end

    def handle_event(_event, _params, state), do: {:noreply, state}

    @impl true
    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def render(assigns) do
      %{temperature: Map.get(assigns, :temperature, 0)}
    end
  end

  defmodule LegacyScreen do
    use ProjectionUI, :screen

    @impl true
    def mount(_params, _session, state) do
      {:ok, %{state | assigns: %{temperature: 70}}}
    end

    @impl true
    def handle_event("inc_temperature", _params, state) do
      next_assigns = Map.update(state.assigns, :temperature, 1, &(&1 + 1))
      {:noreply, %{state | assigns: next_assigns}}
    end

    def handle_event(_event, _params, state), do: {:noreply, state}

    @impl true
    def render(assigns) do
      %{temperature: Map.get(assigns, :temperature, 0)}
    end
  end

  test "screen-style handle_event updates VM through intent patch" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_module: ThermostatScreen,
           port_owner: self()
         ]}
      )

    assert {:ok, [render]} = Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})
    assert render["vm"][:temperature] == 70
    assert render["rev"] == 1

    assert {:ok, []} =
             Session.handle_ui_envelope(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 123,
               "name" => "inc_temperature",
               "payload" => %{}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 200
    assert patch["t"] == "patch"
    assert patch["sid"] == "S1"
    assert patch["rev"] == 2
    assert patch["ack"] == 123
    assert [%{"op" => "replace", "path" => "/temperature", "value" => 71}] = patch["ops"]
  end

  test "screen session is passed to mount" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_module: ThermostatScreen,
           screen_session: %{"base_temperature" => 72},
           port_owner: self()
         ]}
      )

    assert {:ok, [render]} = Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})
    assert render["vm"][:temperature] == 72
  end

  test "full diff fallback preserves behavior for legacy screens without changed tracking" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_module: LegacyScreen,
           port_owner: self()
         ]}
      )

    assert {:ok, [render]} = Session.handle_ui_envelope(session, %{"t" => "ready", "sid" => "S1"})
    assert render["vm"][:temperature] == 70

    assert {:ok, []} =
             Session.handle_ui_envelope(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 124,
               "name" => "inc_temperature",
               "payload" => %{}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 200
    assert patch["t"] == "patch"
    assert patch["sid"] == "S1"
    assert patch["ack"] == 124
    assert [%{"op" => "replace", "path" => "/temperature", "value" => 71}] = patch["ops"]
  end
end
