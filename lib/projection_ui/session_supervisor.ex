defmodule ProjectionUI.SessionSupervisor do
  @moduledoc """
  Supervises one authoritative `Projection.Session` and its `ProjectionUI.PortOwner`.

  Strategy is `:rest_for_one` to ensure port restarts follow session restarts.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    session_name = Keyword.get(opts, :session_name, Projection.Session)
    port_owner_name = Keyword.get(opts, :port_owner_name, ProjectionUI.PortOwner)
    router = Keyword.get(opts, :router)
    route = Keyword.get(opts, :route)
    screen_module = Keyword.get(opts, :screen_module)
    screen_params = Keyword.get(opts, :screen_params)
    screen_session = Keyword.get(opts, :screen_session)
    subscription_hook = Keyword.get(opts, :subscription_hook)

    session_opts =
      [
        name: session_name,
        sid: Keyword.get(opts, :sid),
        tick_ms: Keyword.get(opts, :tick_ms),
        port_owner: port_owner_name
      ]
      |> maybe_put(:router, router)
      |> maybe_put(:route, route)
      |> maybe_put(:screen_module, screen_module)
      |> maybe_put(:screen_params, screen_params)
      |> maybe_put(:screen_session, screen_session)
      |> maybe_put(:subscription_hook, subscription_hook)

    children = [
      {Projection.Session, session_opts},
      {ProjectionUI.PortOwner,
       [
         name: port_owner_name,
         session: session_name,
         command: Keyword.get(opts, :command),
         args: Keyword.get(opts, :args, []),
         env: Keyword.get(opts, :env, []),
         cd: Keyword.get(opts, :cd, File.cwd!())
       ]}
    ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 5,
      max_seconds: 30
    )
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
