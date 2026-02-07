defmodule Projection.Router do
  @moduledoc """
  Route and navigation helpers for Projection sessions.

  Design notes:
  - route identity is a stable route `name`
  - route params are runtime data carried on stack entries
  - `screen_session` is a routing boundary (inspired by LiveView `live_session`)
  """

  use Projection.Router.DSL

  alias ProjectionUI.Screens.Clock
  alias ProjectionUI.Screens.Devices

  screen_session :main do
    screen("/clock", Clock, :show)
    screen("/devices", Devices, :index)
  end

  screen_session :admin do
    screen("/admin", Clock, :index, as: :admin)
  end
end
