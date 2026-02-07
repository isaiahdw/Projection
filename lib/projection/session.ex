defmodule Projection.Session do
  @moduledoc """
  Authoritative per-UI-session process.

  Responsibilities:
  - accept `ready` envelopes
  - respond with `render` envelopes from current VM state
  - keep monotonic `rev`
  - keep stable `sid` for a running session
  - emit periodic `patch` updates from screen state changes
  - optionally run route-aware screen switching via `Projection.Router`
  """

  use GenServer

  require Logger

  alias Projection.Patch
  alias Projection.Protocol
  alias Projection.Router
  alias ProjectionUI.PortOwner
  alias ProjectionUI.State

  @type state :: %{
          sid: String.t() | nil,
          rev: non_neg_integer(),
          vm: map(),
          tick_ms: pos_integer() | nil,
          tick_ref: reference() | nil,
          port_owner: GenServer.server() | nil,
          router: module() | nil,
          nav: Router.nav() | nil,
          app_title: String.t(),
          screen_params: map(),
          screen_session: map(),
          screen_module: module(),
          screen_state: State.t(),
          subscriptions: MapSet.t(term()),
          subscription_hook: (atom(), term() -> any())
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec handle_ui_envelope(GenServer.server(), map()) :: {:ok, [map()]}
  def handle_ui_envelope(session, envelope) when is_map(envelope) do
    GenServer.call(session, {:ui_envelope, envelope})
  end

  @spec handle_ui_envelope_async(GenServer.server(), map()) :: :ok
  def handle_ui_envelope_async(session, envelope) when is_map(envelope) do
    GenServer.cast(session, {:ui_envelope_async, envelope})
  end

  @spec snapshot(GenServer.server()) :: state()
  def snapshot(session), do: GenServer.call(session, :snapshot)

  @impl true
  def init(opts) do
    router = normalize_router(Keyword.get(opts, :router))
    screen_session = normalize_screen_session(Keyword.get(opts, :screen_session, %{}))
    app_title = normalize_app_title(Keyword.get(opts, :app_title, "Projection Demo"))
    subscription_hook = normalize_subscription_hook(Keyword.get(opts, :subscription_hook))

    {screen_module, screen_params, screen_state, nav} =
      init_screen_context(opts, router, screen_session)

    state =
      %{
        sid: Keyword.get(opts, :sid),
        rev: 0,
        vm: %{},
        tick_ms: normalize_tick_ms(Keyword.get(opts, :tick_ms)),
        tick_ref: nil,
        port_owner: Keyword.get(opts, :port_owner),
        router: router,
        nav: nav,
        app_title: app_title,
        screen_params: screen_params,
        screen_session: screen_session,
        screen_module: screen_module,
        screen_state: screen_state,
        subscriptions: MapSet.new(),
        subscription_hook: subscription_hook
      }
      |> sync_subscriptions()

    {:ok, %{state | vm: render_vm(state)}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:ui_envelope, envelope}, _from, state) do
    {:ok, outbound, next_state} = process_ui_envelope(envelope, state)
    {:reply, {:ok, outbound}, next_state}
  end

  @impl true
  def handle_cast({:ui_envelope_async, envelope}, state) do
    {:ok, outbound, next_state} = process_ui_envelope(envelope, state)
    {:noreply, dispatch_outbound(next_state, outbound)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = %{state | tick_ref: nil}
    screen_state = dispatch_screen_info(state.screen_module, :tick, state.screen_state)
    next_state = apply_screen_update(state, screen_state, nil)
    {:noreply, maybe_schedule_tick(next_state)}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state
    |> Map.get(:subscriptions, MapSet.new())
    |> Enum.each(fn topic -> dispatch_subscription(state, :unsubscribe, topic) end)

    :ok
  end

  defp process_ui_envelope(envelope, state) do
    case envelope do
      %{"t" => "ready", "sid" => incoming_sid} when is_binary(incoming_sid) ->
        sid = ensure_stable_sid(state.sid, incoming_sid)
        rev = state.rev + 1
        render = Protocol.render_envelope(sid, rev, state.vm)
        next_state = maybe_schedule_tick(%{state | sid: sid, rev: rev})
        {:ok, [render], next_state}

      %{"t" => "intent", "name" => name} = intent when is_binary(name) ->
        payload = normalize_payload(Map.get(intent, "payload"))
        ack = normalize_ack(Map.get(intent, "id"))

        case maybe_handle_route_intent(name, payload, ack, state) do
          {:handled, next_state} ->
            {:ok, [], next_state}

          :unhandled ->
            screen_state =
              dispatch_screen_event(state.screen_module, name, payload, state.screen_state)

            next_state = apply_screen_update(state, screen_state, ack)
            {:ok, [], next_state}
        end

      _ ->
        {:ok, [], state}
    end
  end

  defp maybe_handle_route_intent(_name, _payload, _ack, %{router: nil}), do: :unhandled

  defp maybe_handle_route_intent("ui.route.navigate", payload, ack, state) do
    {:handled, apply_route_navigate(state, payload, ack)}
  end

  defp maybe_handle_route_intent("ui.route.patch", payload, ack, state) do
    {:handled, apply_route_patch(state, payload, ack)}
  end

  defp maybe_handle_route_intent("ui.back", _payload, ack, state) do
    {:handled, apply_route_back(state, ack)}
  end

  defp maybe_handle_route_intent(_name, _payload, _ack, _state), do: :unhandled

  defp apply_route_navigate(state, payload, ack) do
    to_name = Map.get(payload, "to") || Map.get(payload, "arg")
    params = normalize_screen_params(Map.get(payload, "params", %{}))

    with true <- is_binary(to_name),
         {:ok, false} <- state.router.screen_session_transition?(state.nav, to_name),
         {:ok, nav} <- state.router.navigate(state.nav, to_name, params),
         {:ok, route_def} <- state.router.current_route(nav) do
      screen_state = mount_screen!(route_def.screen_module, params, state.screen_session)

      state
      |> Map.merge(%{
        nav: nav,
        screen_module: route_def.screen_module,
        screen_params: params
      })
      |> sync_subscriptions()
      |> apply_screen_update(screen_state, ack)
    else
      {:ok, true} ->
        Logger.warning("blocked cross screen_session navigation to #{inspect(to_name)}")
        state

      _ ->
        state
    end
  end

  defp apply_route_patch(state, payload, ack) do
    params_patch = normalize_screen_params(Map.get(payload, "params", %{}))
    nav = state.router.patch(state.nav, params_patch)
    current = state.router.current(nav)

    with {:ok, route_def} <- state.router.current_route(nav) do
      screen_state =
        dispatch_screen_params(
          route_def.screen_module,
          current.params,
          state.screen_state,
          state.screen_session
        )

      state
      |> Map.merge(%{
        nav: nav,
        screen_module: route_def.screen_module,
        screen_params: current.params
      })
      |> sync_subscriptions()
      |> apply_screen_update(screen_state, ack)
    else
      _ -> state
    end
  end

  defp apply_route_back(state, ack) do
    with {:ok, nav} <- state.router.back(state.nav),
         {:ok, route_def} <- state.router.current_route(nav) do
      current = state.router.current(nav)
      screen_state = mount_screen!(route_def.screen_module, current.params, state.screen_session)

      state
      |> Map.merge(%{
        nav: nav,
        screen_module: route_def.screen_module,
        screen_params: current.params
      })
      |> sync_subscriptions()
      |> apply_screen_update(screen_state, ack)
    else
      _ -> state
    end
  end

  defp init_screen_context(opts, nil, screen_session) do
    screen_params = normalize_screen_params(Keyword.get(opts, :screen_params, %{}))
    screen_module = Keyword.get(opts, :screen_module, ProjectionUI.Screens.Clock)
    screen_state = mount_screen!(screen_module, screen_params, screen_session)
    {screen_module, screen_params, screen_state, nil}
  end

  defp init_screen_context(opts, router, screen_session) do
    route_name = normalize_route_name(Keyword.get(opts, :route, router.default_route_name()))
    screen_params = normalize_screen_params(Keyword.get(opts, :screen_params, %{}))

    with {:ok, nav} <- router.initial_nav(route_name, screen_params),
         {:ok, route_def} <- router.current_route(nav) do
      screen_state = mount_screen!(route_def.screen_module, screen_params, screen_session)
      {route_def.screen_module, screen_params, screen_state, nav}
    else
      {:error, reason} ->
        raise ArgumentError, "invalid initial route #{inspect(route_name)}: #{inspect(reason)}"
    end
  end

  defp ensure_stable_sid(nil, incoming_sid), do: incoming_sid
  defp ensure_stable_sid(existing_sid, _incoming_sid), do: existing_sid

  defp mount_screen!(screen_module, params, session) do
    initial_assigns =
      if function_exported?(screen_module, :schema, 0) do
        screen_module.schema()
      else
        %{}
      end

    initial_state = State.new(initial_assigns)

    if function_exported?(screen_module, :mount, 3) do
      case screen_module.mount(params, session, initial_state) do
        {:ok, %State{} = state} ->
          state

        other ->
          raise "invalid mount response from #{inspect(screen_module)}: #{inspect(other)}"
      end
    else
      initial_state
    end
  end

  defp dispatch_screen_event(screen_module, event, payload, %State{} = state) do
    if function_exported?(screen_module, :handle_event, 3) do
      case screen_module.handle_event(event, payload, state) do
        {:noreply, %State{} = next_state} ->
          next_state

        other ->
          Logger.warning(
            "invalid handle_event response from #{inspect(screen_module)}: #{inspect(other)}"
          )

          state
      end
    else
      state
    end
  end

  defp dispatch_screen_params(screen_module, params, %State{} = state, session) do
    if function_exported?(screen_module, :handle_params, 2) do
      case screen_module.handle_params(params, state) do
        {:noreply, %State{} = next_state} ->
          next_state

        other ->
          Logger.warning(
            "invalid handle_params response from #{inspect(screen_module)}: #{inspect(other)}"
          )

          state
      end
    else
      mount_screen!(screen_module, params, session)
    end
  end

  defp dispatch_screen_info(screen_module, message, %State{} = state) do
    if function_exported?(screen_module, :handle_info, 2) do
      case screen_module.handle_info(message, state) do
        {:noreply, %State{} = next_state} ->
          next_state

        other ->
          Logger.warning(
            "invalid handle_info response from #{inspect(screen_module)}: #{inspect(other)}"
          )

          state
      end
    else
      state
    end
  end

  defp render_vm(%{router: nil, screen_module: screen_module, screen_state: screen_state}) do
    render_screen(screen_module, screen_state.assigns)
  end

  defp render_vm(state) do
    current = state.router.current(state.nav)

    %{
      app: %{title: state.app_title},
      nav: state.router.to_vm(state.nav),
      screen: %{
        name: current.name,
        action: current.action,
        vm: render_screen(state.screen_module, state.screen_state.assigns)
      }
    }
  end

  defp render_screen(screen_module, assigns) when is_map(assigns) do
    if function_exported?(screen_module, :render, 1) do
      screen_module.render(assigns)
    else
      defaults =
        if function_exported?(screen_module, :schema, 0) do
          screen_module.schema()
        else
          %{}
        end

      if map_size(defaults) == 0 do
        assigns
      else
        defaults
        |> Map.merge(Map.take(assigns, Map.keys(defaults)))
      end
    end
  end

  defp apply_screen_update(state, %State{} = screen_state, ack) do
    next_state = %{state | screen_state: screen_state}
    next_vm = render_vm(next_state)
    ops = vm_patch_ops(state.vm, next_vm)

    next_state = %{next_state | vm: next_vm}

    case {state.sid, ops} do
      {_sid, []} ->
        next_state

      {nil, _ops} ->
        next_state

      {sid, _ops} ->
        rev = state.rev + 1
        patch_opts = if is_nil(ack), do: [], else: [ack: ack]
        patch = Protocol.patch_envelope(sid, rev, ops, patch_opts)

        next_state
        |> Map.put(:rev, rev)
        |> dispatch_outbound([patch])
    end
  end

  defp vm_patch_ops(previous_vm, next_vm) when is_map(previous_vm) and is_map(next_vm) do
    diff_map(previous_vm, next_vm, [])
  end

  defp diff_map(previous, current, tokens) when is_map(previous) and is_map(current) do
    previous
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
    |> Enum.flat_map(fn key ->
      key_tokens = tokens ++ [to_string(key)]
      previous_has_key? = Map.has_key?(previous, key)
      current_has_key? = Map.has_key?(current, key)

      cond do
        previous_has_key? and current_has_key? ->
          previous_value = Map.fetch!(previous, key)
          current_value = Map.fetch!(current, key)
          diff_value(previous_value, current_value, key_tokens)

        current_has_key? ->
          [Patch.add(Patch.pointer(key_tokens), Map.fetch!(current, key))]

        true ->
          [Patch.remove(Patch.pointer(key_tokens))]
      end
    end)
  end

  defp diff_value(previous, current, tokens) when is_map(previous) and is_map(current) do
    if previous == current do
      []
    else
      diff_map(previous, current, tokens)
    end
  end

  defp diff_value(previous, current, tokens) do
    if previous == current do
      []
    else
      [Patch.replace(Patch.pointer(tokens), current)]
    end
  end

  defp sync_subscriptions(state) do
    desired = desired_subscriptions(state)
    current = Map.get(state, :subscriptions, MapSet.new())

    unsubscribe_topics = MapSet.difference(current, desired)
    subscribe_topics = MapSet.difference(desired, current)

    Enum.each(unsubscribe_topics, fn topic ->
      dispatch_subscription(state, :unsubscribe, topic)
    end)

    Enum.each(subscribe_topics, fn topic ->
      dispatch_subscription(state, :subscribe, topic)
    end)

    %{state | subscriptions: desired}
  end

  defp desired_subscriptions(%{
         screen_module: screen_module,
         screen_params: screen_params,
         screen_session: screen_session
       }) do
    if function_exported?(screen_module, :subscriptions, 2) do
      screen_module.subscriptions(screen_params, screen_session)
      |> normalize_subscriptions()
    else
      MapSet.new()
    end
  end

  defp normalize_subscriptions(topics) when is_list(topics), do: MapSet.new(topics)
  defp normalize_subscriptions(_topics), do: MapSet.new()

  defp dispatch_subscription(state, action, topic) do
    try do
      state.subscription_hook.(action, topic)
    rescue
      error ->
        Logger.warning(
          "subscription hook failed for #{action} #{inspect(topic)}: #{inspect(error)}"
        )
    end
  end

  defp normalize_ack(ack) when is_integer(ack), do: ack
  defp normalize_ack(_ack), do: nil

  defp normalize_payload(payload) when is_map(payload), do: payload
  defp normalize_payload(_payload), do: %{}

  defp normalize_screen_params(params) when is_map(params), do: params
  defp normalize_screen_params(_params), do: %{}

  defp normalize_router(nil), do: nil
  defp normalize_router(router) when is_atom(router), do: router
  defp normalize_router(_router), do: nil

  defp normalize_route_name(name) when is_binary(name), do: name
  defp normalize_route_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_route_name(_name), do: Router.default_route_name()

  defp normalize_app_title(title) when is_binary(title) and title != "", do: title
  defp normalize_app_title(_title), do: "Projection Demo"

  defp dispatch_outbound(%{port_owner: nil} = state, _envelopes), do: state

  defp dispatch_outbound(%{port_owner: port_owner} = state, envelopes) do
    if GenServer.whereis(port_owner) do
      Enum.each(envelopes, fn envelope ->
        PortOwner.send_envelope(port_owner, envelope)
      end)
    end

    state
  end

  defp maybe_schedule_tick(%{tick_ms: nil} = state), do: state

  defp maybe_schedule_tick(%{tick_ms: _tick_ms, tick_ref: tick_ref} = state)
       when is_reference(tick_ref),
       do: state

  defp maybe_schedule_tick(%{tick_ms: tick_ms} = state) do
    ref = Process.send_after(self(), :tick, tick_ms)
    %{state | tick_ref: ref}
  end

  defp normalize_tick_ms(tick_ms) when is_integer(tick_ms) and tick_ms > 0, do: tick_ms
  defp normalize_tick_ms(_tick_ms), do: nil

  defp normalize_screen_session(session) when is_map(session), do: session

  defp normalize_screen_session(other) do
    raise ArgumentError, "expected :screen_session to be a map, got: #{inspect(other)}"
  end

  defp normalize_subscription_hook(nil), do: fn _action, _topic -> :ok end
  defp normalize_subscription_hook(fun) when is_function(fun, 2), do: fun

  defp normalize_subscription_hook(other) do
    raise ArgumentError,
          "expected :subscription_hook to be a 2-arity function, got: #{inspect(other)}"
  end
end
