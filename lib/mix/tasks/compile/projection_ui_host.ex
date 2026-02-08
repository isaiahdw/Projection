defmodule Mix.Tasks.Compile.ProjectionUiHost do
  @moduledoc """
  Compiler task that builds the Slint UI host binary and copies it to `priv/ui_host/`.

  Uses `--release` in `:prod` Mix env, debug profile otherwise.
  """

  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    manifest = Path.expand("slint/ui_host/Cargo.toml")

    if File.regular?(manifest) do
      sync_runtime_support!(manifest)
      build_ui_host!(manifest)
      copy_ui_host_binary!()
    end

    {:ok, []}
  rescue
    error ->
      {:error, ["projection_ui_host failed: #{Exception.message(error)}"]}
  end

  defp build_ui_host!(manifest) do
    build_args =
      case Mix.env() do
        :prod -> ["build", "--release", "--manifest-path", manifest]
        _ -> ["build", "--manifest-path", manifest]
      end

    {output, status} = System.cmd("cargo", build_args, stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("failed to build ui_host (exit #{status})\n#{output}")
    end
  end

  defp sync_runtime_support!(manifest) do
    with {:ok, cargo_toml} <- File.read(manifest),
         true <- String.contains?(cargo_toml, "runtime_support/projection_ui_host_runtime") do
      source = runtime_source_dir!()

      target =
        Path.expand(
          Path.join(["slint", "ui_host", "runtime_support", "projection_ui_host_runtime"])
        )

      File.rm_rf!(target)
      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(source, target)
    else
      _ -> :ok
    end
  end

  defp runtime_source_dir! do
    case Mix.Project.deps_paths() do
      %{projection: dep_path} ->
        source = Path.join(dep_path, "slint/ui_host_runtime")

        if File.regular?(Path.join(source, "Cargo.toml")) do
          source
        else
          Mix.raise("projection_ui_host_runtime crate not found at #{source}")
        end

      _ ->
        source = Path.expand(Path.join(["slint", "ui_host_runtime"]))

        if File.regular?(Path.join(source, "Cargo.toml")) do
          source
        else
          Mix.raise("projection_ui_host_runtime crate not found at #{source}")
        end
    end
  end

  defp copy_ui_host_binary! do
    suffix = if match?({:win32, _}, :os.type()), do: ".exe", else: ""
    profile = if Mix.env() == :prod, do: "release", else: "debug"

    source =
      Path.expand(Path.join(["slint", "ui_host", "target", profile, "ui_host" <> suffix]))

    unless File.regular?(source) do
      Mix.raise("ui_host executable not found at #{source}")
    end

    destination_dir = Path.expand(Path.join(["priv", "ui_host"]))
    destination = Path.join(destination_dir, "ui_host" <> suffix)

    File.mkdir_p!(destination_dir)
    File.cp!(source, destination)
  end
end
