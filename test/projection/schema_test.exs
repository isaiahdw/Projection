defmodule Projection.SchemaTest do
  use ExUnit.Case, async: true

  alias ProjectionUI.Schema
  alias Projection.Session

  defmodule DemoScreen do
    use ProjectionUI, :screen

    schema do
      field(:title, :string, default: "Ready")
      field(:enabled, :bool, default: true)
      field(:count, :integer, default: 7)
      field(:ratio, :float, default: 1.5)
    end

    @impl true
    def mount(_params, _session, state), do: {:ok, state}

    @impl true
    def handle_event(_event, _params, state), do: {:noreply, state}

    @impl true
    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def render(assigns) do
      %{
        count: Map.get(assigns, :count, 7),
        enabled: Map.get(assigns, :enabled, true),
        ratio: Map.get(assigns, :ratio, 1.5),
        title: Map.get(assigns, :title, "Ready")
      }
    end
  end

  test "schema/0 returns defaults and metadata is normalized" do
    assert DemoScreen.schema() == %{
             count: 7,
             enabled: true,
             ratio: 1.5,
             title: "Ready"
           }

    assert DemoScreen.__projection_schema__() == [
             %{name: :count, type: :integer, default: 7},
             %{name: :enabled, type: :bool, default: true},
             %{name: :ratio, type: :float, default: 1.5},
             %{name: :title, type: :string, default: "Ready"}
           ]
  end

  test "validate_render!/1 validates type and key contract" do
    assert :ok == Schema.validate_render!(DemoScreen)
  end

  test "session seeds mount state from schema defaults" do
    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_module: DemoScreen
         ]}
      )

    assert {:ok, [render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert render["vm"][:title] == "Ready"
    assert render["vm"][:enabled] == true
    assert render["vm"][:count] == 7
    assert render["vm"][:ratio] == 1.5
  end
end
