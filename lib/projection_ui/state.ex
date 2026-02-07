defmodule ProjectionUI.State do
  @moduledoc """
  Minimal screen-state struct and assign helpers used by Projection screen modules.

  This is not a network socket. It is a small container for screen assigns.
  """

  @missing_key :__projection_missing_key__

  @enforce_keys [:assigns, :changed]
  defstruct assigns: %{}, changed: MapSet.new()

  @type t :: %__MODULE__{
          assigns: map(),
          changed: MapSet.t(atom())
        }

  @doc """
  Creates a new state with the given initial assigns.

  The change set starts empty — initial assigns are not marked as changed.
  """
  @spec new(map()) :: t()
  def new(assigns \\ %{}) when is_map(assigns) do
    %__MODULE__{assigns: assigns, changed: MapSet.new()}
  end

  @doc """
  Sets `key` to `value` in the state's assigns.

  If `value` is identical (`===`) to the current value, the state is returned
  unchanged and the key is **not** marked as changed.
  """
  @spec assign(t(), atom(), any()) :: t()
  def assign(%__MODULE__{} = state, key, value) when is_atom(key) do
    current = Map.get(state.assigns, key, @missing_key)

    if current === value do
      state
    else
      %{
        state
        | assigns: Map.put(state.assigns, key, value),
          changed: MapSet.put(state.changed, key)
      }
    end
  end

  @doc "Applies `fun` to the current value of `key` and assigns the result."
  @spec update(t(), atom(), (any() -> any())) :: t()
  def update(%__MODULE__{} = state, key, fun) when is_atom(key) and is_function(fun, 1) do
    current = Map.get(state.assigns, key)
    assign(state, key, fun.(current))
  end

  @doc "Returns a sorted list of assign keys that have been modified since the last clear."
  @spec changed_fields(t()) :: [atom()]
  def changed_fields(%__MODULE__{} = state) do
    state.changed
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @doc "Resets the change set to empty. Called by the session after diffing."
  @spec clear_changed(t()) :: t()
  def clear_changed(%__MODULE__{} = state) do
    %{state | changed: MapSet.new()}
  end
end
