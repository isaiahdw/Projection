defmodule Projection.M3ListPatchTest do
  use ExUnit.Case, async: true

  alias Projection.Session

  defmodule DevicesScreen do
    use ProjectionUI, :screen

    schema do
      field(:devices, :map, default: %{order: [], by_id: %{}})
    end

    @impl true
    def mount(_params, _session, state) do
      order = Enum.map(1..500, &"dev-#{&1}")

      by_id =
        Enum.into(order, %{}, fn id ->
          {id, %{name: "Device #{id}", status_text: "Online"}}
        end)

      {:ok, assign(state, :devices, %{order: order, by_id: by_id})}
    end

    @impl true
    def handle_event("set_status", %{"id" => id, "status_text" => status_text}, state) do
      devices =
        state.assigns
        |> Map.fetch!(:devices)
        |> put_in([:by_id, id, :status_text], status_text)

      {:noreply, assign(state, :devices, devices)}
    end

    def handle_event(_event, _params, state), do: {:noreply, state}

    @impl true
    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def render(assigns), do: %{devices: Map.fetch!(assigns, :devices)}
  end

  test "500-row seed and single-row update emits one stable-id patch without full render" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_module: DevicesScreen,
           host_bridge: self()
         ]}
      )

    assert {:ok, [render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert render["t"] == "render"
    assert render["rev"] == 1
    assert length(render["vm"][:devices][:order]) == 500

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 77,
               "name" => "set_status",
               "payload" => %{"id" => "dev-250", "status_text" => "Offline (2m)"}
             })

    assert_receive {:"$gen_cast", {:send_envelope, patch}}, 200

    assert patch["t"] == "patch"
    assert patch["sid"] == "S1"
    assert patch["rev"] == 2
    assert patch["ack"] == 77

    assert patch["ops"] == [
             %{
               "op" => "replace",
               "path" => "/devices/by_id/dev-250/status_text",
               "value" => "Offline (2m)"
             }
           ]

    snapshot = Session.snapshot(session)
    assert length(snapshot.vm.devices.order) == 500
    assert Enum.at(snapshot.vm.devices.order, 249) == "dev-250"
    assert snapshot.vm.devices.by_id["dev-250"].status_text == "Offline (2m)"
  end
end
