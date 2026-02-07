defmodule ProjectionUI.Screens.Devices do
  @moduledoc """
  Screen controller for the devices list demo.
  """

  use ProjectionUI, :screen

  schema do
    field(:devices, :id_table, columns: [:name, :status], default: %{order: [], by_id: %{}})
  end

  @impl true
  def mount(params, _session, state) do
    total = Map.get(params, "count", 25)
    devices = seed_devices(total)
    {:ok, assign(state, :devices, devices)}
  end

  @spec subscriptions(map(), map()) :: [String.t()]
  @impl true
  def subscriptions(_params, _session) do
    ["devices"]
  end

  @impl true
  def handle_event("set_status", %{"id" => id} = payload, state) do
    devices = Map.get(state.assigns, :devices, %{order: [], by_id: %{}})
    status = Map.get(payload, "status") || Map.get(payload, "status_text")

    case {status, get_in(devices, [:by_id, id])} do
      {status, %{}} when is_binary(status) ->
        next_devices = put_in(devices, [:by_id, id, :status], status)
        {:noreply, assign(state, :devices, next_devices)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_event(_event, _params, state), do: {:noreply, state}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp seed_devices(total) when is_integer(total) and total > 0 do
    order = Enum.map(1..total, &"dev-#{&1}")

    by_id =
      Enum.into(order, %{}, fn id ->
        {id, %{name: "Device #{id}", status: "Online"}}
      end)

    %{order: order, by_id: by_id}
  end

  defp seed_devices(_total), do: seed_devices(25)
end
