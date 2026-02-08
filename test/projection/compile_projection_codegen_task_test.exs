defmodule Projection.CompileProjectionCodegenTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule AliasRouteRouter do
    use Projection.Router.DSL

    alias Projection.TestScreens.Devices

    screen_session :main do
      screen("/monitoring", Devices, :index, as: :monitoring)
    end
  end

  test "compile.projection_codegen completes without recursive loadpath failures" do
    original_router_module = Application.get_env(:projection, :router_module)
    original_screen_modules = Application.get_env(:projection, :screen_modules)

    Application.delete_env(:projection, :router_module)
    Application.put_env(:projection, :screen_modules, [Projection.TestScreens.Clock])

    on_exit(fn ->
      if is_nil(original_router_module) do
        Application.delete_env(:projection, :router_module)
      else
        Application.put_env(:projection, :router_module, original_router_module)
      end

      if is_nil(original_screen_modules) do
        Application.delete_env(:projection, :screen_modules)
      else
        Application.put_env(:projection, :screen_modules, original_screen_modules)
      end
    end)

    Mix.Task.reenable("projection.codegen")

    capture_io(fn ->
      assert {:ok, []} = Mix.Tasks.Compile.ProjectionCodegen.run([])
    end)
  end

  test "projection.codegen raises when a screen declares unsupported :map fields" do
    module_name = :"MapFieldScreen#{System.unique_integer([:positive])}"
    module = Module.concat([Projection, module_name])

    source = """
    defmodule #{inspect(module)} do
      use ProjectionUI, :screen

      schema do
        field :data, :map, default: %{}
      end
    end
    """

    Code.compile_string(source)

    original_router_module = Application.get_env(:projection, :router_module)
    original_screen_modules = Application.get_env(:projection, :screen_modules)

    Application.delete_env(:projection, :router_module)
    Application.put_env(:projection, :screen_modules, [module])

    on_exit(fn ->
      if is_nil(original_router_module) do
        Application.delete_env(:projection, :router_module)
      else
        Application.put_env(:projection, :router_module, original_router_module)
      end

      if is_nil(original_screen_modules) do
        Application.delete_env(:projection, :screen_modules)
      else
        Application.put_env(:projection, :screen_modules, original_screen_modules)
      end
    end)

    Mix.Task.reenable("projection.codegen")

    assert_raise ArgumentError, ~r/does not support.*:map/, fn ->
      capture_io(fn ->
        Mix.Tasks.Projection.Codegen.run([])
      end)
    end
  end

  test "projection.codegen maps aliased route names to the referenced screen id" do
    original_router_module = Application.get_env(:projection, :router_module)
    original_screen_modules = Application.get_env(:projection, :screen_modules)
    Application.put_env(:projection, :router_module, AliasRouteRouter)
    Application.delete_env(:projection, :screen_modules)

    on_exit(fn ->
      if original_router_module do
        Application.put_env(:projection, :router_module, original_router_module)
      else
        Application.delete_env(:projection, :router_module)
      end

      if is_nil(original_screen_modules) do
        Application.delete_env(:projection, :screen_modules)
      else
        Application.put_env(:projection, :screen_modules, original_screen_modules)
      end

      Mix.Task.reenable("projection.codegen")

      capture_io(fn ->
        previous_allow_empty = System.get_env("PROJECTION_ALLOW_EMPTY")
        System.put_env("PROJECTION_ALLOW_EMPTY", "1")

        try do
          Mix.Tasks.Projection.Codegen.run([])
        after
          if is_nil(previous_allow_empty) do
            System.delete_env("PROJECTION_ALLOW_EMPTY")
          else
            System.put_env("PROJECTION_ALLOW_EMPTY", previous_allow_empty)
          end
        end
      end)
    end)

    Mix.Task.reenable("projection.codegen")

    capture_io(fn ->
      Mix.Tasks.Projection.Codegen.run([])
    end)

    mod_rs = File.read!("slint/ui_host/src/generated/mod.rs")

    assert mod_rs =~ "Some(\"monitoring\") => ScreenId::Devices"
    refute mod_rs =~ "Some(\"devices\") => ScreenId::Devices"
  end
end
