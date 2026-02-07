defmodule ProjectionUI.Schema do
  @moduledoc """
  Typed VM schema DSL for screen modules.

  Supported scalar types:
  - `:string`
  - `:bool`
  - `:integer`
  - `:float`
  """

  @allowed_types [:string, :bool, :integer, :float]

  defmacro __using__(_opts) do
    quote do
      import ProjectionUI.Schema, only: [schema: 1, field: 2, field: 3]

      Module.register_attribute(__MODULE__, :projection_schema_fields, accumulate: true)
      @before_compile ProjectionUI.Schema
    end
  end

  defmacro schema(do: block) do
    block
  end

  defmacro field(name, type, opts \\ []) do
    caller = __CALLER__
    expanded_name = Macro.expand(name, caller)
    expanded_type = Macro.expand(type, caller)
    expanded_opts = Macro.expand(opts, caller)

    validate_name!(expanded_name, caller)
    validate_type!(expanded_type, caller)
    validate_opts!(expanded_opts, caller)

    default =
      case Keyword.fetch(expanded_opts, :default) do
        {:ok, value} -> value
        :error -> default_for_type(expanded_type)
      end

    validate_default!(expanded_name, expanded_type, default, caller)

    normalized_opts = Keyword.put(expanded_opts, :default, default)

    quote do
      @projection_schema_fields {unquote(expanded_name), unquote(expanded_type),
                                 unquote(Macro.escape(normalized_opts))}
    end
  end

  defmacro __before_compile__(env) do
    normalized_schema =
      env.module
      |> Module.get_attribute(:projection_schema_fields)
      |> Enum.reverse()
      |> normalize_schema!(env)

    defaults = Map.new(normalized_schema, fn field -> {field.name, field.default} end)

    quote do
      @doc false
      @spec schema() :: map()
      def schema, do: unquote(Macro.escape(defaults))

      @doc false
      @spec __projection_schema__() :: [map()]
      def __projection_schema__, do: unquote(Macro.escape(normalized_schema))
    end
  end

  @spec validate_render!(module()) :: :ok
  def validate_render!(module) when is_atom(module) do
    ensure_exported!(module, :schema, 0)
    ensure_exported!(module, :render, 1)
    ensure_exported!(module, :__projection_schema__, 0)

    schema_defaults = module.schema()
    metadata = module.__projection_schema__()
    rendered = module.render(schema_defaults)

    unless is_map(rendered) do
      raise ArgumentError,
            "#{inspect(module)}.render/1 must return a map, got: #{inspect(rendered)}"
    end

    expected_keys = metadata |> Enum.map(& &1.name) |> Enum.sort()
    rendered_keys = rendered |> Map.keys() |> Enum.sort()

    if expected_keys != rendered_keys do
      raise ArgumentError,
            "#{inspect(module)}.render/1 keys #{inspect(rendered_keys)} " <>
              "do not match schema keys #{inspect(expected_keys)}"
    end

    Enum.each(metadata, fn %{name: name, type: type} ->
      value = Map.fetch!(rendered, name)

      unless value_matches_type?(type, value) do
        raise ArgumentError,
              "#{inspect(module)}.render/1 returned invalid value for #{inspect(name)} " <>
                "(expected #{inspect(type)}, got #{inspect(value)})"
      end
    end)

    :ok
  end

  defp normalize_schema!(fields, env) do
    fields
    |> Enum.map(fn {name, type, opts} ->
      default = Keyword.fetch!(opts, :default)
      %{name: name, type: type, default: default}
    end)
    |> detect_duplicates!(env)
    |> Enum.sort_by(&Atom.to_string(&1.name))
  end

  defp detect_duplicates!(fields, env) do
    duplicated_names =
      fields
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_name, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicated_names != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "duplicate schema fields: #{inspect(Enum.sort(duplicated_names))}"
    end

    fields
  end

  defp ensure_exported!(module, function, arity) do
    unless function_exported?(module, function, arity) do
      raise ArgumentError,
            "#{inspect(module)} must export #{function}/#{arity} for schema validation"
    end
  end

  defp validate_name!(name, _caller) when is_atom(name), do: :ok

  defp validate_name!(name, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "schema field name must be an atom, got: #{inspect(name)}"
  end

  defp validate_type!(type, _caller) when type in @allowed_types, do: :ok

  defp validate_type!(type, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "unsupported schema type #{inspect(type)}. Allowed types: #{inspect(@allowed_types)}"
  end

  defp validate_opts!(opts, _caller) when is_list(opts), do: :ok

  defp validate_opts!(opts, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "field options must be a keyword list, got: #{inspect(opts)}"
  end

  defp validate_default!(name, type, default, caller) do
    unless value_matches_type?(type, default) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "invalid default for #{inspect(name)}. Expected #{inspect(type)}, got #{inspect(default)}"
    end
  end

  defp value_matches_type?(:string, value), do: is_binary(value)
  defp value_matches_type?(:bool, value), do: is_boolean(value)
  defp value_matches_type?(:integer, value), do: is_integer(value)
  defp value_matches_type?(:float, value), do: is_float(value)

  defp default_for_type(:string), do: ""
  defp default_for_type(:bool), do: false
  defp default_for_type(:integer), do: 0
  defp default_for_type(:float), do: 0.0
end
