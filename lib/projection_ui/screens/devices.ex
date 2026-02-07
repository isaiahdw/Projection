defmodule ProjectionUI.Screens.Devices do
  @moduledoc """
  Screen controller for the devices list demo.
  """

  use ProjectionUI, :screen

  schema do
    field(:devices, :map, default: %{order: [], by_id: %{}})
  end

  @impl true
  def mount(params, _session, state) do
    total = Map.get(params, "count", 25)
    {:ok, assign(state, :devices, seed_devices(total))}
  end

  @spec subscriptions(map(), map()) :: [String.t()]
  @impl true
  def subscriptions(_params, _session) do
    ["devices"]
  end

  @impl true
  def handle_event("set_status", %{"id" => id, "status_text" => status_text}, state) do
    devices = Map.fetch!(state.assigns, :devices)

    case get_in(devices, [:by_id, id]) do
      %{} ->
        next_devices = put_in(devices, [:by_id, id, :status_text], status_text)
        {:noreply, assign(state, :devices, next_devices)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_event(_event, _params, state), do: {:noreply, state}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def render(assigns), do: %{devices: Map.fetch!(assigns, :devices)}

  defp seed_devices(total) when is_integer(total) and total > 0 do
    order = Enum.map(1..total, &"dev-#{&1}")

    by_id =
      Enum.into(order, %{}, fn id ->
        {id, %{name: "Device #{id}", status_text: "Online"}}
      end)

    %{order: order, by_id: by_id}
  end

  defp seed_devices(_total), do: seed_devices(25)
end
