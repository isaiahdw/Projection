defmodule Mix.Tasks.Ui.Preview do
  use Mix.Task

  @shortdoc "Builds ui_host and runs a screen preview (ready -> render + clock patches)"

  @moduledoc """
  Builds `slint/ui_host`, starts a `ProjectionUI.SessionSupervisor`, and keeps the
  preview session alive so the Rust host can handshake and render.

  Options:
    * `--sid` session id sent by UI host (default: "S1")
    * `--route` initial route name (default: "clock")
    * `--screen-params` JSON object passed to screen `mount/3` params (default: "{}")
    * `--tick-ms` session tick interval in milliseconds (default: 1000)
    * `--backend` sets `SLINT_BACKEND` for ui_host (default: "winit")
    * `--startup-timeout-ms` wait time for host `ready -> render` handshake (default: 5000)
  """

  @switches [
    sid: :string,
    route: :string,
    screen_params: :string,
    tick_ms: :integer,
    backend: :string,
    startup_timeout_ms: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    sid = Keyword.get(opts, :sid, "S1")
    route = Keyword.get(opts, :route, "clock")
    screen_params = parse_screen_params(Keyword.get(opts, :screen_params, "{}"))
    tick_ms = Keyword.get(opts, :tick_ms, 1_000)
    backend = Keyword.get(opts, :backend, System.get_env("SLINT_BACKEND") || "winit")
    startup_timeout_ms = Keyword.get(opts, :startup_timeout_ms, 5_000)

    Mix.shell().info("Preparing preview runtime...")
    Mix.Task.run("app.start")

    build_ui_host!()
    command = ui_host_executable!()

    Mix.shell().info("Starting preview with sid=#{sid}, backend=#{backend}, ui_host=#{command}")

    {:ok, _sup} =
      Projection.start_session(
        name: Projection.PreviewSupervisor,
        session_name: Projection.PreviewSession,
        host_bridge_name: Projection.PreviewHostBridge,
        sid: sid,
        router: Projection.Router,
        route: route,
        screen_params: screen_params,
        tick_ms: tick_ms,
        command: command,
        env: [{"PROJECTION_SID", sid}, {"SLINT_BACKEND", backend}],
        cd: File.cwd!()
      )

    wait_for_initial_render!(
      Projection.PreviewSession,
      Projection.PreviewHostBridge,
      startup_timeout_ms
    )

    Mix.shell().info("Preview running. Press Ctrl+C twice to exit.")
    Process.sleep(:infinity)
  end

  defp build_ui_host! do
    Mix.shell().info("Building slint/ui_host...")

    {output, status} =
      System.cmd("cargo", ["build", "--manifest-path", "slint/ui_host/Cargo.toml"],
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("failed to build ui_host (exit #{status})\n#{output}")
    end
  end

  defp ui_host_executable! do
    suffix = if match?({:win32, _}, :os.type()), do: ".exe", else: ""

    executable =
      Path.expand(Path.join(["slint", "ui_host", "target", "debug", "ui_host" <> suffix]))

    if File.regular?(executable) do
      executable
    else
      Mix.raise("ui_host executable not found at #{executable}")
    end
  end

  defp parse_screen_params(raw) do
    case Jason.decode(raw) do
      {:ok, params} when is_map(params) ->
        params

      {:ok, _other} ->
        Mix.raise("--screen-params must decode to a JSON object")

      {:error, error} ->
        Mix.raise("--screen-params must be valid JSON: #{Exception.message(error)}")
    end
  end

  defp wait_for_initial_render!(session_name, host_bridge_name, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_initial_render(session_name, host_bridge_name, deadline_ms, timeout_ms)
  end

  defp wait_for_initial_render!(_session_name, _host_bridge_name, timeout_ms) do
    Mix.raise("--startup-timeout-ms must be a positive integer, got: #{inspect(timeout_ms)}")
  end

  defp do_wait_for_initial_render(session_name, host_bridge_name, deadline_ms, timeout_ms) do
    case safe_session_snapshot(session_name) do
      %{rev: rev} when is_integer(rev) and rev > 0 ->
        Mix.shell().info("UI handshake complete (session rev=#{rev}).")
        :ok

      _snapshot ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          Mix.raise("""
          ui.preview timed out waiting for initial host handshake (ready -> render) after #{timeout_ms}ms.
          Session status: #{session_debug_status(session_name)}
          Host bridge status: #{host_bridge_debug_status(host_bridge_name)}
          Try: `mix ui.preview --backend winit --startup-timeout-ms 15000`
          """)
        else
          Process.sleep(100)
          do_wait_for_initial_render(session_name, host_bridge_name, deadline_ms, timeout_ms)
        end
    end
  end

  defp safe_session_snapshot(session_name) do
    case Process.whereis(session_name) do
      nil ->
        nil

      _pid ->
        Projection.Session.snapshot(session_name)
    end
  rescue
    _ -> nil
  end

  defp session_debug_status(session_name) do
    case safe_session_snapshot(session_name) do
      nil ->
        "not running"

      %{rev: rev, sid: sid, screen_module: screen_module} ->
        "rev=#{rev}, sid=#{inspect(sid)}, screen=#{inspect(screen_module)}"

      snapshot ->
        "running (unexpected snapshot shape: #{inspect(snapshot)})"
    end
  end

  defp host_bridge_debug_status(host_bridge_name) do
    case Process.whereis(host_bridge_name) do
      nil ->
        "not running"

      _pid ->
        case :sys.get_state(host_bridge_name) do
          %{port: nil, command: command, reconnect_idx: reconnect_idx} ->
            "running, port=disconnected, command=#{inspect(command)}, reconnect_idx=#{reconnect_idx}"

          %{port: port, command: command} when is_port(port) ->
            "running, port=connected, command=#{inspect(command)}"

          state ->
            "running (unexpected state shape: #{inspect(state)})"
        end
    end
  rescue
    _ -> "running (failed to inspect state)"
  end
end
