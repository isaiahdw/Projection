defmodule Projection.Telemetry do
  @moduledoc """
  Telemetry helper for Projection runtime events.

  All events are emitted under the `[:projection, ...]` namespace.
  """

  @type event_suffix :: [atom()]
  @type measurements :: map()
  @type metadata :: map()

  @doc """
  Emits a Projection telemetry event.

  If the `:telemetry` dependency is unavailable, this becomes a no-op.
  """
  @spec execute(event_suffix(), measurements(), metadata()) :: :ok
  def execute(event_suffix, measurements, metadata)
      when is_list(event_suffix) and is_map(measurements) and is_map(metadata) do
    if function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute([:projection | event_suffix], measurements, metadata)
    end

    :ok
  end
end
