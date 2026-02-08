defmodule Mix.Tasks.Projection.New do
  use Mix.Task

  import Mix.Generator

  @shortdoc "Generates a new Projection + Slint starter project"

  @moduledoc """
  Generates a new Projection app with:

  * Projection compile integration
  * a starter router and `Hello` screen
  * starter Slint UI files
  * a starter Rust ui_host crate

      mix projection.new path/to/my_app
      mix projection.new path/to/my_app --module MyApp --app my_app
  """

  @switches [module: :string, app: :string, force: :boolean]
  @aliases [m: :module, a: :app, f: :force]
  @template_root Path.expand("../../../priv/templates/projection.new", __DIR__)

  @impl Mix.Task
  def run(args) do
    {opts, parsed, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    target =
      case parsed do
        [path] -> path
        _ -> Mix.raise(usage())
      end

    app = opts[:app] || infer_app(target)
    module = opts[:module] || infer_module(app)

    validate_app!(app)
    validate_module!(module)

    target_path = Path.expand(target)
    ensure_destination!(target_path, opts[:force] || false)

    assigns = [app: app, module: module]

    create_directory(target_path)
    copy_templates!(target_path, assigns, opts[:force] || false)

    Mix.shell().info("""

    Your Projection project was created successfully.

    Next steps:
        cd #{target}
        mix deps.get
        mix compile
        mix run -e "#{module}.Demo.run()"
    """)
  end

  defp copy_templates!(target_path, assigns, force?) do
    @template_root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.each(fn source ->
      relative =
        source
        |> Path.relative_to(@template_root)
        |> String.replace("__app__", assigns[:app])

      destination =
        relative
        |> String.trim_trailing(".eex")
        |> then(&Path.join(target_path, &1))

      create_directory(Path.dirname(destination))

      if String.ends_with?(source, ".eex") do
        content = EEx.eval_file(source, assigns)
        create_file(destination, content, force: force?)
      else
        copy_file(source, destination, force: force?)
      end
    end)
  end

  defp ensure_destination!(path, true), do: create_directory(path)

  defp ensure_destination!(path, false) do
    case File.ls(path) do
      {:error, :enoent} ->
        :ok

      {:ok, []} ->
        :ok

      {:ok, _entries} ->
        Mix.raise(
          "destination #{path} already exists and is not empty (use --force to overwrite)"
        )

      {:error, reason} ->
        Mix.raise("cannot access destination #{path}: #{inspect(reason)}")
    end
  end

  defp infer_app(target) do
    target
    |> Path.basename()
    |> Macro.underscore()
  end

  defp infer_module(app) do
    app
    |> Macro.camelize()
    |> ensure_non_empty_module()
  end

  defp ensure_non_empty_module(""), do: "ProjectionApp"
  defp ensure_non_empty_module(module), do: module

  defp validate_app!(app) do
    unless app =~ ~r/^[a-z][a-z0-9_]*$/ do
      Mix.raise("invalid app name #{inspect(app)} (expected snake_case, starting with a-z)")
    end
  end

  defp validate_module!(module) do
    unless module =~ ~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/ do
      Mix.raise("invalid module name #{inspect(module)}")
    end
  end

  defp usage do
    """
    Usage:
        mix projection.new PATH [--module Module.Name] [--app app_name] [--force]
    """
  end
end
