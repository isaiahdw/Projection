defmodule Mix.Tasks.Projection.Codegen do
  use Mix.Task

  @shortdoc "Generates typed Rust screen bindings from ProjectionUI schema metadata"

  @moduledoc """
  Generates Rust binding glue under `slint/ui_host/src/generated/` from
  `__projection_schema__/0` metadata defined in `ProjectionUI.Screens.*` modules.
  """

  @supported_types [:string, :bool, :integer, :float]

  @impl Mix.Task
  def run(_args) do
    ensure_app_loaded!()

    router_module = discover_router_module()
    routes = discover_routes(router_module)

    specs =
      discover_screen_modules()
      |> Enum.map(&build_screen_spec/1)
      |> Enum.filter(fn spec -> spec.fields != [] end)
      |> Enum.sort_by(& &1.module_name)

    generated_dir = Path.join(File.cwd!(), "slint/ui_host/src/generated")
    File.mkdir_p!(generated_dir)

    screen_results =
      specs
      |> Task.async_stream(
        fn spec ->
          path = Path.join(generated_dir, "#{spec.file_name}.rs")
          write_file_if_changed(path, render_screen_module(spec))
        end,
        ordered: false,
        timeout: :infinity,
        max_concurrency: max_concurrency()
      )
      |> Enum.map(&unwrap_task_result!/1)

    mod_result =
      write_file_if_changed(Path.join(generated_dir, "mod.rs"), render_generated_mod(specs))

    routes_result =
      write_file_if_changed(Path.join(generated_dir, "routes.slint"), render_routes_slint(routes))

    written_count =
      Enum.count(screen_results ++ [mod_result, routes_result], fn
        :written -> true
        _ -> false
      end)

    Mix.shell().info(
      "projection.codegen generated #{length(specs)} screen module(s), #{length(routes)} route constant(s), wrote #{written_count} file(s)"
    )
  end

  defp discover_router_module do
    Application.get_env(:projection, :router_module, Projection.Router)
  end

  defp discover_routes(router_module) do
    if Code.ensure_loaded?(router_module) and function_exported?(router_module, :route_defs, 0) do
      router_module.route_defs()
      |> Map.values()
      |> Enum.map(&normalize_route!/1)
      |> Enum.sort_by(& &1.name)
    else
      []
    end
  end

  defp normalize_route!(%{name: name, path: path, route_key: route_key})
       when is_binary(name) and is_binary(path) and is_atom(route_key) do
    %{name: name, path: path, route_key: route_key}
  end

  defp normalize_route!(%{name: name, path: path}) when is_binary(name) and is_binary(path) do
    %{name: name, path: path, route_key: String.to_atom(name)}
  end

  defp normalize_route!(route) do
    raise ArgumentError, "invalid route metadata for codegen: #{inspect(route)}"
  end

  defp discover_screen_modules do
    :projection
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(&screen_module?/1)
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> Enum.filter(&function_exported?(&1, :__projection_schema__, 0))
    |> Enum.sort_by(&Atom.to_string/1)
  end

  defp screen_module?(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.ProjectionUI.Screens.")
  end

  defp build_screen_spec(module) do
    metadata = module.__projection_schema__()

    fields =
      metadata
      |> Enum.map(&normalize_field!/1)
      |> Enum.sort_by(&Atom.to_string(&1.name))

    %{
      module: module,
      module_name: Atom.to_string(module),
      screen_name: module |> Module.split() |> List.last() |> Macro.underscore(),
      file_name: module |> Module.split() |> List.last() |> Macro.underscore(),
      fields: fields
    }
  end

  defp normalize_field!(%{name: name, type: type, default: default})
       when is_atom(name) and type in @supported_types do
    %{name: name, type: type, default: default}
  end

  defp normalize_field!(field) do
    raise ArgumentError,
          "invalid schema field metadata for codegen: #{inspect(field)}"
  end

  defp ensure_app_loaded! do
    Mix.Task.run("loadpaths")

    case Application.load(:projection) do
      :ok -> :ok
      {:error, {:already_loaded, :projection}} -> :ok
      {:error, reason} -> Mix.raise("failed to load :projection application: #{inspect(reason)}")
    end
  end

  defp write_file_if_changed(path, content) when is_binary(path) and is_binary(content) do
    case File.read(path) do
      {:ok, existing} when existing == content ->
        :unchanged

      _ ->
        File.write!(path, content)
        :written
    end
  end

  defp unwrap_task_result!({:ok, status}), do: status

  defp unwrap_task_result!({:exit, reason}) do
    Mix.raise("projection.codegen worker crashed: #{inspect(reason)}")
  end

  defp max_concurrency do
    System.schedulers_online()
  end

  defp render_generated_mod([]) do
    """
    use crate::AppWindow;
    use crate::protocol::PatchOp;
    use serde_json::Value;
    use std::convert::TryFrom;

    #[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
    pub enum ScreenId {
        #[default]
        Unknown,
    }

    pub fn apply_render(_ui: &AppWindow, _vm: &Value) -> Result<ScreenId, String> {
        Ok(ScreenId::Unknown)
    }

    pub fn apply_patch(_ui: &AppWindow, _screen_id: ScreenId, _ops: &[PatchOp]) -> Result<(), String> {
        Ok(())
    }
    """
  end

  defp render_generated_mod(specs) do
    [first | rest] = specs

    module_lines =
      specs
      |> Enum.map(fn spec -> "pub mod #{spec.file_name};" end)
      |> Enum.join("\n")

    enum_variants =
      rest
      |> Enum.map_join("\n", fn spec ->
        "    #{camelize(spec.screen_name)},"
      end)

    enum_from_vm_arms =
      specs
      |> Enum.map_join("\n", fn spec ->
        "        Some(\"#{spec.screen_name}\") => ScreenId::#{camelize(spec.screen_name)},"
      end)

    render_dispatch_arms =
      specs
      |> Enum.map_join("\n", fn spec ->
        "        ScreenId::#{camelize(spec.screen_name)} => #{spec.file_name}::apply_render(ui, vm),"
      end)

    patch_dispatch_arms =
      specs
      |> Enum.map_join("\n", fn spec ->
        "        ScreenId::#{camelize(spec.screen_name)} => #{spec.file_name}::apply_patch(ui, ops),"
      end)

    """
    use crate::AppWindow;
    use crate::protocol::PatchOp;
    use serde_json::Value;

    #{module_lines}

    #[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
    pub enum ScreenId {
        #[default]
        #{camelize(first.screen_name)},
    #{enum_variants}
    }

    fn screen_id_from_vm(vm: &Value) -> ScreenId {
        match vm.pointer("/screen/name").and_then(Value::as_str) {
    #{enum_from_vm_arms}
            _ => ScreenId::#{camelize(first.screen_name)},
        }
    }

    pub fn apply_render(ui: &AppWindow, vm: &Value) -> Result<ScreenId, String> {
        let screen_id = screen_id_from_vm(vm);

        match screen_id {
    #{render_dispatch_arms}
        }?;

        Ok(screen_id)
    }

    pub fn apply_patch(ui: &AppWindow, screen_id: ScreenId, ops: &[PatchOp]) -> Result<(), String> {
        match screen_id {
    #{patch_dispatch_arms}
        }
    }
    """
  end

  defp render_screen_module(spec) do
    render_field_setters =
      spec.fields
      |> Enum.map_join("\n", fn field ->
        """
        set_#{field.name}_from_vm(ui, vm)?;
        """
      end)

    patch_match_arms =
      spec.fields
      |> Enum.map_join("\n", fn field ->
        top_path = "/" <> Atom.to_string(field.name)
        nested_path = "/screen/vm/" <> Atom.to_string(field.name)

        """
                    "#{top_path}" | "#{nested_path}" => set_#{field.name}_from_value(ui, path, value)?,
        """
      end)

    remove_match_arms =
      spec.fields
      |> Enum.map_join("\n", fn field ->
        top_path = "/" <> Atom.to_string(field.name)
        nested_path = "/screen/vm/" <> Atom.to_string(field.name)

        """
                    "#{top_path}" | "#{nested_path}" => set_#{field.name}_default(ui),
        """
      end)

    field_helpers =
      spec.fields
      |> Enum.map_join("\n", &render_field_helper/1)

    parse_helpers =
      spec.fields
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join("\n", &render_parse_helper/1)

    """
    use crate::AppWindow;
    use crate::protocol::PatchOp;
    use serde_json::Value;

    pub fn apply_render(ui: &AppWindow, vm: &Value) -> Result<(), String> {
    #{render_field_setters}
        bump_vm_rev(ui);
        Ok(())
    }

    pub fn apply_patch(ui: &AppWindow, ops: &[PatchOp]) -> Result<(), String> {
        for op in ops {
            match op {
                PatchOp::Replace { path, value } | PatchOp::Add { path, value } => {
                    match path.as_str() {
    #{patch_match_arms}
                        _ => {}
                    }
                }
                PatchOp::Remove { path } => {
                    match path.as_str() {
    #{remove_match_arms}
                        _ => {}
                    }
                }
            }
        }

        bump_vm_rev(ui);
        Ok(())
    }

    #{field_helpers}

    fn bump_vm_rev(ui: &AppWindow) {
        let next = ui.get_vm_rev().wrapping_add(1);
        ui.set_vm_rev(next);
    }

    #{parse_helpers}
    """
  end

  defp render_field_helper(%{name: name, type: type, default: default}) do
    field = Atom.to_string(name)
    default_literal = rust_literal(type, default)
    set_value_expr = rust_set_value_expr(name, type)

    """
    fn set_#{field}_from_vm(ui: &AppWindow, vm: &Value) -> Result<(), String> {
        if let Some(value) = vm.pointer("/screen/vm/#{field}") {
            return set_#{field}_from_value(ui, "/screen/vm/#{field}", value);
        }

        if let Some(value) = vm.pointer("/#{field}") {
            return set_#{field}_from_value(ui, "/#{field}", value);
        }

        set_#{field}_default(ui);
        Ok(())
    }

    fn set_#{field}_from_value(ui: &AppWindow, path: &str, value: &Value) -> Result<(), String> {
        #{set_value_expr}
    }

    fn set_#{field}_default(ui: &AppWindow) {
        ui.set_#{field}(#{default_literal});
    }
    """
  end

  defp rust_set_value_expr(name, :string) do
    """
    let parsed = parse_string(value, path)?;
        ui.set_#{name}(parsed.into());
        Ok(())
    """
  end

  defp rust_set_value_expr(name, :bool) do
    """
    let parsed = parse_bool(value, path)?;
        ui.set_#{name}(parsed);
        Ok(())
    """
  end

  defp rust_set_value_expr(name, :integer) do
    """
    let parsed = parse_integer(value, path)?;
        let casted = i32::try_from(parsed)
            .map_err(|_| format!("value out of range for Slint int at path {path}: {parsed}"))?;
        ui.set_#{name}(casted);
        Ok(())
    """
  end

  defp rust_set_value_expr(name, :float) do
    """
    let parsed = parse_float(value, path)?;
        let casted = parsed as f32;
        if !casted.is_finite() {
            return Err(format!("non-finite float at path {path}: {parsed}"));
        }
        ui.set_#{name}(casted);
        Ok(())
    """
  end

  defp rust_literal(:string, value), do: "\"#{escape_string(value)}\".into()"
  defp rust_literal(:bool, true), do: "true"
  defp rust_literal(:bool, false), do: "false"
  defp rust_literal(:integer, value), do: "i32::try_from(#{value}i64).unwrap_or_default()"
  defp rust_literal(:float, value), do: "#{format_float(value)}f32"

  defp escape_string(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp format_float(value) when is_float(value) do
    :erlang.float_to_binary(value, [:compact, decimals: 16])
  end

  defp camelize(value) when is_binary(value) do
    value
    |> Macro.camelize()
    |> String.replace(".", "")
  end

  defp render_parse_helper(:string) do
    """
    fn parse_string(value: &Value, path: &str) -> Result<String, String> {
        value
            .as_str()
            .map(ToOwned::to_owned)
            .ok_or_else(|| format!("expected string at path {path}"))
    }
    """
  end

  defp render_parse_helper(:bool) do
    """
    fn parse_bool(value: &Value, path: &str) -> Result<bool, String> {
        value
            .as_bool()
            .ok_or_else(|| format!("expected bool at path {path}"))
    }
    """
  end

  defp render_parse_helper(:integer) do
    """
    fn parse_integer(value: &Value, path: &str) -> Result<i64, String> {
        value
            .as_i64()
            .ok_or_else(|| format!("expected integer at path {path}"))
    }
    """
  end

  defp render_parse_helper(:float) do
    """
    fn parse_float(value: &Value, path: &str) -> Result<f64, String> {
        value
            .as_f64()
            .ok_or_else(|| format!("expected float at path {path}"))
    }
    """
  end

  defp render_routes_slint(routes) do
    route_props =
      routes
      |> Enum.map_join("\n", fn route ->
        "    out property <string> #{slint_identifier(route.route_key)}: \"#{escape_slint_string(route.name)}\";"
      end)

    """
    // generated by mix projection.codegen; do not edit manually
    export global Routes {
    #{route_props}
    }
    """
  end

  defp slint_identifier(route_key) when is_atom(route_key) do
    route_key
    |> Atom.to_string()
    |> String.replace(~r/[^A-Za-z0-9_]/, "_")
    |> ensure_non_numeric_identifier()
  end

  defp ensure_non_numeric_identifier(""), do: "route"

  defp ensure_non_numeric_identifier(identifier) do
    case identifier do
      <<first::utf8, _rest::binary>> when first in ?0..?9 -> "route_" <> identifier
      _ -> identifier
    end
  end

  defp escape_slint_string(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
