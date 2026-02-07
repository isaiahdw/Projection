defmodule ProjectionUI do
  @moduledoc """
  UI-layer entrypoint for screen modules in Projection.
  """

  def screen do
    quote do
      @behaviour ProjectionUI.Screen

      alias ProjectionUI.State
      import ProjectionUI.State, only: [assign: 3, update: 3]
      use ProjectionUI.Schema

      @doc false
      @spec mount(map(), map(), State.t()) :: {:ok, State.t()}
      @impl true
      def mount(_params, _session, state) do
        {:ok, state}
      end

      @doc false
      @spec handle_event(String.t(), map(), State.t()) :: {:noreply, State.t()}
      @impl true
      def handle_event(_event, _params, state) do
        {:noreply, state}
      end

      @doc false
      @spec handle_params(map(), State.t()) :: {:noreply, State.t()}
      @impl true
      def handle_params(_params, state) do
        {:noreply, state}
      end

      @doc false
      @spec handle_info(any(), State.t()) :: {:noreply, State.t()}
      @impl true
      def handle_info(_message, state) do
        {:noreply, state}
      end

      @doc false
      @spec subscriptions(map(), map()) :: [term()]
      @impl true
      def subscriptions(_params, _session) do
        []
      end

      @doc false
      @spec render(map()) :: map()
      @impl true
      def render(assigns) when is_map(assigns) do
        defaults = schema()

        if map_size(defaults) == 0 do
          assigns
        else
          defaults
          |> Map.merge(Map.take(assigns, Map.keys(defaults)))
        end
      end

      defoverridable mount: 3,
                     handle_event: 3,
                     handle_params: 2,
                     handle_info: 2,
                     subscriptions: 2,
                     render: 1
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
