defmodule ProjectionUI.Screen do
  @moduledoc """
  Minimal callback contract for Projection screen modules.
  """

  alias ProjectionUI.State

  @callback schema() :: map()
  @callback __projection_schema__() :: [map()]
  @callback mount(params :: map(), session :: map(), state :: State.t()) ::
              {:ok, State.t()}
  @callback handle_event(event :: String.t(), params :: map(), state :: State.t()) ::
              {:noreply, State.t()}
  @callback handle_params(params :: map(), state :: State.t()) ::
              {:noreply, State.t()}
  @callback handle_info(message :: any(), state :: State.t()) ::
              {:noreply, State.t()}
  @callback subscriptions(params :: map(), session :: map()) :: [term()]
  @callback render(assigns :: map()) :: map()

  @optional_callbacks mount: 3,
                      handle_event: 3,
                      handle_params: 2,
                      handle_info: 2,
                      subscriptions: 2,
                      render: 1
end
