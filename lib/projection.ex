defmodule Projection do
  @moduledoc """
  Projection runtime entrypoints.
  """

  @doc """
  Starts a supervised session with its UI host port.

  Delegates to `ProjectionUI.SessionSupervisor.start_link/1`. See that module
  for the full list of accepted options.
  """
  @spec start_session(keyword()) :: Supervisor.on_start()
  def start_session(opts \\ []) do
    ProjectionUI.SessionSupervisor.start_link(opts)
  end
end
