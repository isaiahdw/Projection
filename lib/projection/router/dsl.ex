defmodule Projection.Router.DSL do
  @moduledoc """
  Router DSL for Projection screens.

  Example:

      defmodule MyRouter do
        use Projection.Router.DSL

        screen_session :main do
          screen "/clock", MyApp.Screens.Clock, :show, as: :clock
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Projection.Router.DSL, only: [screen_session: 2, screen: 3, screen: 4]

      Module.register_attribute(__MODULE__, :projection_route_defs, accumulate: true)

      @before_compile Projection.Router.DSL
    end
  end

  defmacro screen_session(name, do: block) do
    caller = __CALLER__
    expanded_name = Macro.expand(name, caller)
    validate_screen_session_name!(expanded_name, caller)
    rewritten_block = inject_screen_session(block, expanded_name)

    quote do
      unquote(rewritten_block)
    end
  end

  defmacro screen(path, screen_module, action) do
    quote do
      screen(unquote(path), unquote(screen_module), unquote(action), [])
    end
  end

  defmacro screen(path, screen_module, action, opts) do
    caller = __CALLER__

    expanded_path = Macro.expand(path, caller)
    expanded_screen_module = Macro.expand(screen_module, caller)
    expanded_action = Macro.expand(action, caller)
    expanded_opts = Macro.expand(opts, caller)
    {current_screen_session, expanded_opts} = Keyword.pop(expanded_opts, :__screen_session__)

    validate_screen_session_name!(current_screen_session, caller)
    validate_path!(expanded_path, caller)
    validate_screen_module!(expanded_screen_module, caller)
    validate_action!(expanded_action, caller)
    validate_opts!(expanded_opts, caller)

    {route_name, route_key} =
      normalize_route_name_and_key!(Keyword.get(expanded_opts, :as), expanded_path, caller)

    route_def = %{
      name: route_name,
      route_key: route_key,
      path: expanded_path,
      screen_module: expanded_screen_module,
      action: expanded_action,
      screen_session: current_screen_session
    }

    quote do
      @projection_route_defs unquote(Macro.escape(route_def))
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:projection_route_defs)
      |> List.wrap()
      |> Enum.reverse()
      |> validate_routes!(env)

    default_route_name = routes |> List.first() |> Map.fetch!(:name)
    routes_by_name = Map.new(routes, &{&1.name, &1})
    route_name_by_key = Map.new(routes, &{&1.route_key, &1.name})
    route_path_by_key = Map.new(routes, &{&1.route_key, &1.path})
    route_keys = Enum.map(routes, & &1.route_key)
    route_names = Enum.map(routes, & &1.name)

    quote do
      @type route_name :: String.t()
      @type route_params :: map()

      @type route_def :: %{
              name: route_name(),
              route_key: atom(),
              path: String.t(),
              screen_module: module(),
              action: atom() | nil,
              screen_session: atom()
            }

      @type route_entry :: %{
              name: route_name(),
              params: route_params(),
              action: atom() | nil
            }

      @type nav :: %{
              stack: [route_entry()]
            }

      @routes unquote(Macro.escape(routes_by_name))
      @route_name_by_key unquote(Macro.escape(route_name_by_key))
      @route_path_by_key unquote(Macro.escape(route_path_by_key))
      @route_keys unquote(Macro.escape(route_keys))
      @route_names unquote(Macro.escape(route_names))
      @default_route_name unquote(default_route_name)

      @spec default_route_name() :: route_name()
      def default_route_name, do: @default_route_name

      @spec route_defs() :: %{route_name() => route_def()}
      def route_defs, do: @routes

      @spec route_keys() :: [atom()]
      def route_keys, do: @route_keys

      @spec route_names() :: [route_name()]
      def route_names, do: @route_names

      @spec route_name(atom()) :: route_name()
      def route_name(route_key) when is_atom(route_key) do
        case @route_name_by_key do
          %{^route_key => route_name} ->
            route_name

          _ ->
            raise ArgumentError, "unknown route key #{inspect(route_key)}"
        end
      end

      @spec route_path(atom()) :: String.t()
      def route_path(route_key) when is_atom(route_key) do
        case @route_path_by_key do
          %{^route_key => route_path} ->
            route_path

          _ ->
            raise ArgumentError, "unknown route key #{inspect(route_key)}"
        end
      end

      @spec resolve(route_name()) :: {:ok, route_def()} | {:error, :unknown_route}
      def resolve(name) when is_binary(name) do
        case @routes do
          %{^name => route_def} -> {:ok, route_def}
          _ -> {:error, :unknown_route}
        end
      end

      def resolve(_name), do: {:error, :unknown_route}

      @spec initial_nav(route_name(), route_params()) :: {:ok, nav()} | {:error, :unknown_route}
      def initial_nav(name, params \\ %{}) when is_map(params) do
        with {:ok, route_def} <- resolve(name) do
          {:ok, %{stack: [entry_for(route_def, params)]}}
        end
      end

      @spec current(nav()) :: route_entry()
      def current(%{stack: [current | _rest]}), do: current
      def current(%{stack: []}), do: raise(ArgumentError, "nav stack cannot be empty")

      @spec navigate(nav(), route_name(), route_params()) ::
              {:ok, nav()} | {:error, :unknown_route}
      def navigate(%{stack: stack} = nav, name, params \\ %{})
          when is_list(stack) and is_map(params) do
        with {:ok, route_def} <- resolve(name) do
          {:ok, %{nav | stack: [entry_for(route_def, params) | stack]}}
        end
      end

      @spec back(nav()) :: {:ok, nav()} | {:error, :root}
      def back(%{stack: [_current]}), do: {:error, :root}

      def back(%{stack: [_current | rest]} = nav) do
        {:ok, %{nav | stack: rest}}
      end

      @spec patch(nav(), route_params()) :: nav()
      def patch(%{stack: [current | rest]} = nav, params_patch) when is_map(params_patch) do
        patched_current = %{current | params: Map.merge(current.params, params_patch)}
        %{nav | stack: [patched_current | rest]}
      end

      @spec current_route(nav()) :: {:ok, route_def()} | {:error, :unknown_route}
      def current_route(nav) do
        nav
        |> current()
        |> Map.fetch!(:name)
        |> resolve()
      end

      @spec screen_session_transition?(nav(), route_name()) ::
              {:ok, boolean()} | {:error, :unknown_route}
      def screen_session_transition?(nav, to_name) when is_binary(to_name) do
        with {:ok, from_route} <- current_route(nav),
             {:ok, to_route} <- resolve(to_name) do
          {:ok, from_route.screen_session != to_route.screen_session}
        end
      end

      @spec live_session_transition?(nav(), route_name()) ::
              {:ok, boolean()} | {:error, :unknown_route}
      def live_session_transition?(nav, to_name), do: screen_session_transition?(nav, to_name)

      @spec to_vm(nav()) :: map()
      def to_vm(nav) do
        current_entry = current(nav)
        stack = Enum.reverse(nav.stack)

        %{
          stack: stack,
          current: current_entry
        }
      end

      defp entry_for(route_def, params) do
        %{
          name: route_def.name,
          params: params,
          action: route_def.action
        }
      end
    end
  end

  defp validate_screen_session_name!(name, _caller) when is_atom(name) and not is_nil(name),
    do: :ok

  defp validate_screen_session_name!(name, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "`screen_session` name must be an atom and defined before `screen`, got: #{inspect(name)}"
  end

  defp validate_path!("/", _caller), do: :ok
  defp validate_path!(<<"/", _::binary>>, _caller), do: :ok

  defp validate_path!(path, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "`screen` path must be a non-empty binary starting with '/', got: #{inspect(path)}"
  end

  defp validate_screen_module!(module, _caller) when is_atom(module), do: :ok

  defp validate_screen_module!(module, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "`screen` module must be an atom module name, got: #{inspect(module)}"
  end

  defp validate_action!(action, _caller) when is_atom(action) or is_nil(action), do: :ok

  defp validate_action!(action, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "`screen` action must be an atom or nil, got: #{inspect(action)}"
  end

  defp validate_opts!(opts, _caller) when is_list(opts), do: :ok

  defp validate_opts!(opts, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "`screen` opts must be a keyword list, got: #{inspect(opts)}"
  end

  defp normalize_route_name_and_key!(nil, path, _caller) do
    route_name =
      path
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> List.last()
      |> case do
        nil -> "root"
        segment -> segment
      end

    {route_name, String.to_atom(route_name)}
  end

  defp normalize_route_name_and_key!(name, _path, _caller) when is_atom(name) do
    {Atom.to_string(name), name}
  end

  defp normalize_route_name_and_key!(name, _path, _caller) when is_binary(name) and name != "" do
    {name, String.to_atom(name)}
  end

  defp normalize_route_name_and_key!(name, _path, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "`screen ... as:` must be an atom or string, got: #{inspect(name)}"
  end

  defp validate_routes!([], env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: "router must define at least one `screen` route"
  end

  defp validate_routes!(routes, env) do
    duplicated_names =
      routes
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_name, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))

    duplicated_paths =
      routes
      |> Enum.group_by(& &1.path)
      |> Enum.filter(fn {_path, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))

    duplicated_route_keys =
      routes
      |> Enum.group_by(& &1.route_key)
      |> Enum.filter(fn {_route_key, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicated_names != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "duplicate route names: #{inspect(Enum.sort(duplicated_names))}"
    end

    if duplicated_paths != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "duplicate route paths: #{inspect(Enum.sort(duplicated_paths))}"
    end

    if duplicated_route_keys != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "duplicate route keys: #{inspect(Enum.sort(duplicated_route_keys))}"
    end

    routes
  end

  defp inject_screen_session(block, screen_session_name) do
    Macro.prewalk(block, fn
      {:screen, meta, [path, screen_module, action]} ->
        opts_with_session = [__screen_session__: screen_session_name]
        {:screen, meta, [path, screen_module, action, opts_with_session]}

      {:screen, meta, [path, screen_module, action, opts]} ->
        opts_with_session =
          if is_list(opts) do
            Keyword.put(opts, :__screen_session__, screen_session_name)
          else
            quote do
              Keyword.put(unquote(opts), :__screen_session__, unquote(screen_session_name))
            end
          end

        {:screen, meta, [path, screen_module, action, opts_with_session]}

      other ->
        other
    end)
  end
end
