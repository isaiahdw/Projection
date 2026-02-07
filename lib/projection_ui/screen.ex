defmodule ProjectionUI.Screen do
  @moduledoc """
  Callback behaviour for Projection screen modules.

  A screen is a stateful UI unit — similar to a Phoenix LiveView — that declares
  a typed schema and handles lifecycle events. Implement this behaviour via
  `use ProjectionUI, :screen`, which provides default implementations for all
  optional callbacks.

  ## Lifecycle

    1. `c:mount/3` — called once when the screen is first loaded or navigated to
    2. `c:handle_params/2` — called on route patches (param changes without remount)
    3. `c:handle_event/3` — called for each user intent from the UI host
    4. `c:handle_info/2` — called for messages like `:tick` or pub/sub broadcasts
    5. `c:render/1` — produces the view-model map from current assigns
    6. `c:subscriptions/2` — declares pub/sub topics for this screen

  All callbacks except `c:schema/0` and `c:__projection_schema__/0` are optional.
  """

  alias ProjectionUI.State

  @doc "Returns default assigns as a `%{field_name => default_value}` map."
  @callback schema() :: map()

  @doc false
  @callback __projection_schema__() :: [map()]

  @doc """
  Called once when a screen is mounted.

  Receives route params, the session map, and an initial `t:ProjectionUI.State.t/0`
  pre-populated with schema defaults.
  """
  @callback mount(params :: map(), session :: map(), state :: State.t()) ::
              {:ok, State.t()}

  @doc """
  Handles a named user intent from the UI host.

  `event` is the intent name (e.g. `"clock.pause"`), and `params` is the
  intent payload map.
  """
  @callback handle_event(event :: String.t(), params :: map(), state :: State.t()) ::
              {:noreply, State.t()}

  @doc """
  Called when route params change without a full remount (via `ui.route.patch`).
  """
  @callback handle_params(params :: map(), state :: State.t()) ::
              {:noreply, State.t()}

  @doc """
  Handles internal messages such as `:tick` or pub/sub broadcasts.
  """
  @callback handle_info(message :: any(), state :: State.t()) ::
              {:noreply, State.t()}

  @doc """
  Returns a list of pub/sub topics this screen should subscribe to.

  Called on mount and navigation. The session diffs against current subscriptions
  and subscribes/unsubscribes as needed.
  """
  @callback subscriptions(params :: map(), session :: map()) :: [term()]

  @doc """
  Produces the view-model map from current assigns.

  The returned map must contain exactly the keys declared in the schema.
  The default implementation passes schema-declared assigns through unchanged.
  """
  @callback render(assigns :: map()) :: map()

  @optional_callbacks mount: 3,
                      handle_event: 3,
                      handle_params: 2,
                      handle_info: 2,
                      subscriptions: 2,
                      render: 1
end
