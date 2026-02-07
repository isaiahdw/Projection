defmodule Projection.CompileProjectionCodegenTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "compile.projection_codegen completes without recursive loadpath failures" do
    Mix.Task.reenable("projection.codegen")

    capture_io(fn ->
      assert {:ok, []} = Mix.Tasks.Compile.ProjectionCodegen.run([])
    end)
  end

  test "projection.codegen raises when a screen declares unsupported :map fields" do
    module_name = :"MapFieldScreen#{System.unique_integer([:positive])}"
    module = Module.concat([ProjectionUI.Screens, module_name])

    source = """
    defmodule #{inspect(module)} do
      use ProjectionUI, :screen

      schema do
        field :data, :map, default: %{}
      end
    end
    """

    Code.compile_string(source)

    original_modules = Application.spec(:projection, :modules) |> List.wrap()
    :ok = :application.set_key(:projection, :modules, [module | original_modules])

    on_exit(fn ->
      :ok = :application.set_key(:projection, :modules, original_modules)
    end)

    Mix.Task.reenable("projection.codegen")

    assert_raise ArgumentError, ~r/does not support.*:map/, fn ->
      capture_io(fn ->
        Mix.Tasks.Projection.Codegen.run([])
      end)
    end
  end
end
