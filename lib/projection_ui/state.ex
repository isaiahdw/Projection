defmodule ProjectionUI.State do
  @moduledoc """
  Minimal screen-state struct and assign helpers used by Projection screen modules.

  This is not a network socket. It is a small container for screen assigns.
  """

  @enforce_keys [:assigns]
  defstruct assigns: %{}

  @type t :: %__MODULE__{
          assigns: map()
        }

  @spec new(map()) :: t()
  def new(assigns \\ %{}) when is_map(assigns) do
    %__MODULE__{assigns: assigns}
  end

  @spec assign(t(), atom(), any()) :: t()
  def assign(%__MODULE__{} = state, key, value) when is_atom(key) do
    %{state | assigns: Map.put(state.assigns, key, value)}
  end

  @spec update(t(), atom(), (any() -> any())) :: t()
  def update(%__MODULE__{} = state, key, fun) when is_atom(key) and is_function(fun, 1) do
    current = Map.get(state.assigns, key)
    assign(state, key, fun.(current))
  end
end
