defmodule Projection.CompileProjectionCodegenTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "compile.projection_codegen completes without recursive loadpath failures" do
    Mix.Task.reenable("projection.codegen")

    capture_io(fn ->
      assert {:ok, []} = Mix.Tasks.Compile.ProjectionCodegen.run([])
    end)
  end
end
