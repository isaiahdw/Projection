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

  defmodule ContainerScreen do
    use ProjectionUI, :screen

    schema do
      field(:devices, :map, default: %{order: [], by_id: %{}})
      field(:tabs, :list, default: ["clock"])
    end

    @impl true
    def render(assigns), do: assigns
  end

  defmodule StatusBadgeComponent do
    use ProjectionUI, :component

    schema do
      field(:label, :string, default: "Badge")
      field(:status, :string, default: "ok")
    end
  end

  defmodule ComponentScreen do
    use ProjectionUI, :screen

    schema do
      field(:title, :string, default: "Dashboard")
      component(:badge, StatusBadgeComponent, default: %{label: "API"})
    end

    @impl true
    def render(assigns), do: assigns
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

  test "schema supports map and list fields" do
    assert ContainerScreen.schema() == %{
             devices: %{order: [], by_id: %{}},
             tabs: ["clock"]
           }

    assert ContainerScreen.__projection_schema__() == [
             %{name: :devices, type: :map, default: %{order: [], by_id: %{}}},
             %{name: :tabs, type: :list, default: ["clock"]}
           ]

    assert :ok == Schema.validate_render!(ContainerScreen)
  end

  test "schema supports reusable component fields" do
    assert ComponentScreen.schema() == %{
             badge: %{label: "API", status: "ok"},
             title: "Dashboard"
           }

    assert [
             %{
               default: %{label: "API", status: "ok"},
               name: :badge,
               type: :component,
               opts: opts
             },
             %{default: "Dashboard", name: :title, type: :string}
           ] = ComponentScreen.__projection_schema__()

    assert Keyword.fetch!(opts, :module) == StatusBadgeComponent
    assert :ok == Schema.validate_render!(ComponentScreen)
  end

  test "screen modules must declare schema do/end" do
    module_name = :"MissingSchema#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    source = """
    defmodule #{inspect(module)} do
      use ProjectionUI, :screen
    end
    """

    assert_raise CompileError, ~r/must declare `schema do \.\.\. end`/, fn ->
      Code.compile_string(source)
    end
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
