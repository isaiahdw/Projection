defmodule Mix.Tasks.Compile.ProjectionCodegen do
  @moduledoc """
  Compiler task that runs `mix projection.codegen` as part of `mix compile`.
  """

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
