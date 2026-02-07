defmodule ProjectionUI.Screens.Clock do
  @moduledoc """
  Screen controller for the initial Projection demo screen.

  Note: timezone offsets are fixed for demo simplicity and do not handle DST.
  """

  use ProjectionUI, :screen

  @timezone_offsets %{
    "UTC" => 0,
    "America/New_York" => -5 * 60 * 60,
    "America/Chicago" => -6 * 60 * 60,
    "America/Denver" => -7 * 60 * 60,
    "America/Los_Angeles" => -8 * 60 * 60
  }
  @max_clock_label_length 24

  schema do
    field(:clock_text, :string, default: "--:--:--")
    field(:clock_running, :bool, default: true)
    field(:clock_timezone, :string, default: "UTC")
    field(:clock_label, :string, default: "Projection Clock")
    field(:clock_label_error, :string, default: "")
  end

  @spec mount(map(), map(), State.t()) :: {:ok, State.t()}
  @impl true
  def mount(params, _session, state) do
    next_state =
      state
      |> maybe_assign_clock_timezone(params)
      |> maybe_assign_clock_text(params)
      |> maybe_assign_clock_label(params)

    {:ok, next_state}
  end

  @spec subscriptions(map(), map()) :: [String.t()]
  @impl true
  def subscriptions(params, _session) do
    timezone = Map.get(params, "clock_timezone", schema()[:clock_timezone])
    ["clock.timezone:" <> timezone]
  end

  @spec handle_event(String.t(), map(), State.t()) :: {:noreply, State.t()}

  @impl true
  def handle_event("clock.pause", _params, state) do
    {:noreply, assign(state, :clock_running, false)}
  end

  def handle_event("clock.resume", _params, state) do
    {:noreply, assign(state, :clock_running, true)}
  end

  def handle_event("clock.set_timezone", payload, state) when is_map(payload) do
    case extract_timezone(payload) do
      {:ok, timezone} ->
        next_state =
          state
          |> assign(:clock_timezone, timezone)
          |> assign(:clock_text, current_clock_text(timezone))

        {:noreply, next_state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_event("clock.commit_label", payload, state) when is_map(payload) do
    case extract_clock_label(payload) do
      {:ok, label} ->
        {:noreply, commit_clock_label(state, label)}

      :error ->
        {:noreply, assign(state, :clock_label_error, "Label must be text.")}
    end
  end

  def handle_event(_event, _params, state) do
    {:noreply, state}
  end

  @spec handle_params(map(), State.t()) :: {:noreply, State.t()}
  @impl true
  def handle_params(params, state) do
    next_state =
      state
      |> maybe_assign_clock_timezone(params)
      |> maybe_assign_clock_text(params)
      |> maybe_assign_clock_label(params)

    {:noreply, next_state}
  end

  @spec handle_info(any(), State.t()) :: {:noreply, State.t()}
  @impl true
  def handle_info(:tick, state) do
    if clock_running?(state) do
      {:noreply, assign(state, :clock_text, current_clock_text(clock_timezone(state)))}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec maybe_assign_clock_text(State.t(), map()) :: State.t()
  defp maybe_assign_clock_text(state, %{"clock_text" => value}) when is_binary(value) do
    assign(state, :clock_text, value)
  end

  defp maybe_assign_clock_text(state, _params), do: state

  @spec maybe_assign_clock_timezone(State.t(), map()) :: State.t()
  defp maybe_assign_clock_timezone(state, %{"clock_timezone" => timezone})
       when is_binary(timezone) do
    if valid_timezone?(timezone) do
      state
      |> assign(:clock_timezone, timezone)
      |> assign(:clock_text, current_clock_text(timezone))
    else
      state
    end
  end

  defp maybe_assign_clock_timezone(state, _params), do: state

  @spec maybe_assign_clock_label(State.t(), map()) :: State.t()
  defp maybe_assign_clock_label(state, %{"clock_label" => label}) when is_binary(label) do
    assign(state, :clock_label, label)
  end

  defp maybe_assign_clock_label(state, _params), do: state

  @spec clock_running?(State.t()) :: boolean()
  defp clock_running?(state) do
    Map.get(state.assigns, :clock_running, true)
  end

  @spec clock_timezone(State.t()) :: String.t()
  defp clock_timezone(state) do
    Map.get(state.assigns, :clock_timezone, schema()[:clock_timezone])
  end

  @spec valid_timezone?(String.t()) :: boolean()
  defp valid_timezone?(timezone), do: Map.has_key?(@timezone_offsets, timezone)

  @spec extract_timezone(map()) :: {:ok, String.t()} | :error
  defp extract_timezone(%{"timezone" => timezone}) when is_binary(timezone) do
    if valid_timezone?(timezone), do: {:ok, timezone}, else: :error
  end

  defp extract_timezone(%{"arg" => timezone}) when is_binary(timezone) do
    if valid_timezone?(timezone), do: {:ok, timezone}, else: :error
  end

  defp extract_timezone(_payload), do: :error

  @spec extract_clock_label(map()) :: {:ok, String.t()} | :error
  defp extract_clock_label(%{"label" => label}) when is_binary(label), do: {:ok, label}
  defp extract_clock_label(%{"arg" => label}) when is_binary(label), do: {:ok, label}
  defp extract_clock_label(_payload), do: :error

  @spec commit_clock_label(State.t(), String.t()) :: State.t()
  defp commit_clock_label(state, raw_label) when is_binary(raw_label) do
    normalized_label = normalize_clock_label(raw_label)

    cond do
      normalized_label == "" ->
        assign(state, :clock_label_error, "Label cannot be empty.")

      String.length(normalized_label) > @max_clock_label_length ->
        truncated_label =
          normalized_label
          |> String.slice(0, @max_clock_label_length)
          |> String.trim_trailing()

        state
        |> assign(:clock_label, truncated_label)
        |> assign(
          :clock_label_error,
          "Label was truncated to #{@max_clock_label_length} characters."
        )

      true ->
        state
        |> assign(:clock_label, normalized_label)
        |> assign(:clock_label_error, "")
    end
  end

  @spec normalize_clock_label(String.t()) :: String.t()
  defp normalize_clock_label(raw_label) when is_binary(raw_label) do
    raw_label
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  @spec current_clock_text(String.t()) :: String.t()
  defp current_clock_text(timezone) do
    offset_seconds = Map.get(@timezone_offsets, timezone, 0)

    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> Time.to_string()
  end
end
