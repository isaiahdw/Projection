defmodule Mix.Tasks.Compile.ProjectionCodegen do
  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    Mix.Task.run("projection.codegen")
    {:ok, []}
  rescue
    error ->
      {:error, ["projection_codegen failed: #{Exception.message(error)}"]}
  end
end
