defmodule Projection do
  @moduledoc """
  Projection runtime entrypoints.
  """

  @spec start_session(keyword()) :: Supervisor.on_start()
  def start_session(opts \\ []) do
    ProjectionUI.SessionSupervisor.start_link(opts)
  end
end
