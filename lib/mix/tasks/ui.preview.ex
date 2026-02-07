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
  """

  @switches [
    sid: :string,
    route: :string,
    screen_params: :string,
    tick_ms: :integer,
    backend: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    sid = Keyword.get(opts, :sid, "S1")
    route = Keyword.get(opts, :route, "clock")
    screen_params = parse_screen_params(Keyword.get(opts, :screen_params, "{}"))
    tick_ms = Keyword.get(opts, :tick_ms, 1_000)
    backend = Keyword.get(opts, :backend, System.get_env("SLINT_BACKEND") || "winit")

    build_ui_host!()
    command = ui_host_executable!()

    Mix.shell().info("Starting preview with sid=#{sid}, backend=#{backend}")

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
end
