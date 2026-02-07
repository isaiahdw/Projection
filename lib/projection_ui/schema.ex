defmodule ProjectionUI.Schema do
  @moduledoc """
  Typed view-model schema DSL for screen modules.

  Every screen must declare a `schema` block listing the fields visible to
  the UI host. These declarations drive codegen (Rust setters) and compile-time
  validation.

  ## Supported types

    * `:string` — default `""`
    * `:bool` — default `false`
    * `:integer` — default `0`
    * `:float` — default `0.0`
    * `:map` — default `%{}`
    * `:list` — default `[]`
    * `:id_table` — default `%{order: [], by_id: %{}}`

  ## Collection guidance

  `:list` is intended for small or low-churn collections. For larger lists
  where row-level updates matter, prefer `:id_table` so patches can target
  stable IDs instead of replacing full lists.

  ## Example

      schema do
        field :greeting, :string, default: "Hello!"
        field :count, :integer
      end

  """

  @allowed_types [:string, :bool, :integer, :float, :map, :list, :id_table]

  defmacro __using__(_opts) do
    quote do
      import ProjectionUI.Schema, only: [schema: 1, field: 2, field: 3]

      Module.register_attribute(__MODULE__, :projection_schema_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :projection_schema_declared, persist: false)
      @projection_schema_declared false
      @before_compile ProjectionUI.Schema
    end
  end

  @doc """
  Declares the screen's view-model schema.

  Must appear exactly once in each screen module. Can be empty if the screen
  has no fields:

      schema do
      end

  """
  defmacro schema(do: block) do
    quote do
      @projection_schema_declared true
      unquote(block)
    end
  end

  @doc """
  Declares a named, typed field inside a `schema` block.

  Accepts an optional `:default` value. If omitted, the type's zero-value is
  used (e.g. `""` for `:string`, `0` for `:integer`).
  """
  defmacro field(name, type, opts \\ []) do
    caller = __CALLER__
    expanded_name = Macro.expand(name, caller)
    expanded_type = Macro.expand(type, caller)
    expanded_opts = expand_literal!(opts, caller, "field options")

    validate_name!(expanded_name, caller)
    validate_type!(expanded_type, caller)
    validate_opts!(expanded_type, expanded_opts, caller)

    default =
      case Keyword.fetch(expanded_opts, :default) do
        {:ok, value} -> value
        :error -> default_for_type(expanded_type)
      end

    validate_default!(expanded_name, expanded_type, default, expanded_opts, caller)

    normalized_opts = Keyword.put(expanded_opts, :default, default)

    quote do
      @projection_schema_fields {unquote(expanded_name), unquote(expanded_type),
                                 unquote(Macro.escape(normalized_opts))}
    end
  end

  defmacro __before_compile__(env) do
    ensure_schema_declared!(env)

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

  @doc """
  Validates that a screen module's `render/1` output matches its schema.

  Raises `ArgumentError` if keys or types don't match. Used by the codegen
  task to catch mismatches at build time.
  """
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

    Enum.each(metadata, fn field ->
      name = field.name
      type = field.type
      opts = Map.get(field, :opts, [])
      value = Map.fetch!(rendered, name)

      unless value_matches_type?(type, value, opts) do
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
      base = %{name: name, type: type, default: default}
      extra_opts = Keyword.delete(opts, :default)
      if extra_opts == [], do: base, else: Map.put(base, :opts, extra_opts)
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

  defp expand_literal!(quoted, caller, label) do
    expanded = Macro.expand(quoted, caller)

    if Macro.quoted_literal?(expanded) do
      {value, _binding} = Code.eval_quoted(expanded, [], caller)
      value
    else
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "#{label} must be compile-time literals, got: #{Macro.to_string(quoted)}"
    end
  end

  defp ensure_schema_declared!(env) do
    declared? = Module.get_attribute(env.module, :projection_schema_declared)

    unless declared? do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "#{inspect(env.module)} must declare `schema do ... end` (it can be empty if needed)"
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

  defp validate_opts!(:id_table, opts, caller) when is_list(opts) do
    case Keyword.get(opts, :columns) do
      columns when is_list(columns) ->
        if columns != [] and Enum.all?(columns, &is_atom/1) do
          :ok
        else
          raise CompileError,
            file: caller.file,
            line: caller.line,
            description:
              ":id_table fields require `columns: [...]` with one or more atom column names"
        end

      _ ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            ":id_table fields require `columns: [...]` with one or more atom column names"
    end
  end

  defp validate_opts!(_type, opts, _caller) when is_list(opts), do: :ok

  defp validate_opts!(_type, opts, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "field options must be a keyword list, got: #{inspect(opts)}"
  end

  defp validate_default!(name, type, default, opts, caller) do
    unless value_matches_type?(type, default, opts) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "invalid default for #{inspect(name)}. Expected #{inspect(type)}, got #{inspect(default)}"
    end
  end

  defp value_matches_type?(:string, value, _opts), do: is_binary(value)
  defp value_matches_type?(:bool, value, _opts), do: is_boolean(value)
  defp value_matches_type?(:integer, value, _opts), do: is_integer(value)
  defp value_matches_type?(:float, value, _opts), do: is_float(value)
  defp value_matches_type?(:map, value, _opts), do: is_map(value)
  defp value_matches_type?(:list, value, _opts), do: is_list(value)
  defp value_matches_type?(:id_table, value, opts), do: valid_id_table?(value, opts)

  defp default_for_type(:string), do: ""
  defp default_for_type(:bool), do: false
  defp default_for_type(:integer), do: 0
  defp default_for_type(:float), do: 0.0
  defp default_for_type(:map), do: %{}
  defp default_for_type(:list), do: []
  defp default_for_type(:id_table), do: %{order: [], by_id: %{}}

  defp valid_id_table?(%{order: order, by_id: by_id}, opts)
       when is_list(order) and is_map(by_id) and is_list(opts) do
    columns =
      opts
      |> Keyword.get(:columns, [])
      |> Enum.map(&Atom.to_string/1)

    columns != [] and
      Enum.all?(order, &is_binary/1) and
      Enum.all?(order, fn id ->
        row = Map.get(by_id, id)
        is_map(row) and Enum.all?(columns, &binary_cell?(row, &1))
      end)
  end

  defp valid_id_table?(_value, _opts), do: false

  defp binary_cell?(row, column) when is_map(row) and is_binary(column) do
    case Map.fetch(row, column) do
      {:ok, value} when is_binary(value) ->
        true

      _ ->
        case maybe_existing_atom(column) do
          {:ok, atom_column} ->
            case Map.fetch(row, atom_column) do
              {:ok, value} when is_binary(value) -> true
              _ -> false
            end

          :error ->
            false
        end
    end
  end

  defp maybe_existing_atom(token) when is_binary(token) do
    try do
      {:ok, String.to_existing_atom(token)}
    rescue
      ArgumentError -> :error
    end
  end
end
