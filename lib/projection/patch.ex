defmodule Projection.Patch do
  @moduledoc """
  JSON Patch helpers for Projection.

  Supports the RFC6902 subset used by Projection (`add`, `remove`, `replace`)
  plus RFC6901 token escaping helpers for pointer paths.
  """

  @typedoc "An RFC 6902 patch operation map with `\"op\"`, `\"path\"`, and optionally `\"value\"` keys."
  @type op :: map()

  @doc "Builds a `replace` op for the given JSON Pointer `path`."
  @spec replace(String.t(), any()) :: op()
  def replace(path, value) when is_binary(path) do
    validate_pointer_path!(path)
    %{"op" => "replace", "path" => path, "value" => value}
  end

  @doc "Builds an `add` op for the given JSON Pointer `path`."
  @spec add(String.t(), any()) :: op()
  def add(path, value) when is_binary(path) do
    validate_pointer_path!(path)
    %{"op" => "add", "path" => path, "value" => value}
  end

  @doc "Builds a `remove` op for the given JSON Pointer `path`."
  @spec remove(String.t()) :: op()
  def remove(path) when is_binary(path) do
    validate_pointer_path!(path)
    %{"op" => "remove", "path" => path}
  end

  @doc """
  Joins a list of path tokens into an RFC 6901 JSON Pointer string.

  Each token is escaped per RFC 6901 (`~` -> `~0`, `/` -> `~1`).

  ## Examples

      iex> Projection.Patch.pointer(["screen", "vm", "clock_text"])
      "/screen/vm/clock_text"

  """
  @spec pointer([String.t()]) :: String.t()
  def pointer(tokens) when is_list(tokens) do
    "/" <> Enum.map_join(tokens, "/", &escape_token/1)
  end

  @doc """
  Escapes a single path token per RFC 6901.

  ## Examples

      iex> Projection.Patch.escape_token("a/b")
      "a~1b"

  """
  @spec escape_token(String.t()) :: String.t()
  def escape_token(token) when is_binary(token) do
    token
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  @doc """
  Unescapes a single RFC 6901 token.

  Returns `{:error, :invalid_escape}` for invalid or truncated `~` escapes.
  """
  @spec unescape_token(String.t()) :: {:ok, String.t()} | {:error, :invalid_escape}
  def unescape_token(token) when is_binary(token) do
    do_unescape_token(token, "")
  end

  @doc """
  Parses an RFC 6901 JSON Pointer into unescaped tokens.

  Accepts `""` (root pointer). Returns `{:error, :invalid_pointer}` when the
  pointer does not start with `/`, and `{:error, :invalid_escape}` when any
  token contains invalid escapes.
  """
  @spec parse_pointer(String.t()) ::
          {:ok, [String.t()]} | {:error, :invalid_pointer | :invalid_escape}
  def parse_pointer(""), do: {:ok, []}

  def parse_pointer(<<"/", rest::binary>>) do
    rest
    |> split_pointer_tokens()
    |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
      case unescape_token(token) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, :invalid_escape} -> {:halt, {:error, :invalid_escape}}
      end
    end)
    |> case do
      {:ok, tokens} -> {:ok, Enum.reverse(tokens)}
      error -> error
    end
  end

  def parse_pointer(_path), do: {:error, :invalid_pointer}

  defp do_unescape_token(<<>>, acc), do: {:ok, acc}

  defp do_unescape_token(<<"~0", rest::binary>>, acc) do
    do_unescape_token(rest, acc <> "~")
  end

  defp do_unescape_token(<<"~1", rest::binary>>, acc) do
    do_unescape_token(rest, acc <> "/")
  end

  defp do_unescape_token(<<"~", _rest::binary>>, _acc), do: {:error, :invalid_escape}

  defp do_unescape_token(<<char::utf8, rest::binary>>, acc) do
    do_unescape_token(rest, <<acc::binary, char::utf8>>)
  end

  defp split_pointer_tokens(rest) do
    :binary.split(rest, "/", [:global])
  end

  defp validate_pointer_path!(path) when is_binary(path) do
    case parse_pointer(path) do
      {:ok, _tokens} ->
        :ok

      {:error, :invalid_pointer} ->
        raise ArgumentError,
              "invalid JSON pointer path #{inspect(path)}: must be empty or start with '/'"

      {:error, :invalid_escape} ->
        raise ArgumentError,
              "invalid JSON pointer path #{inspect(path)}: contains invalid RFC6901 escape sequence"
    end
  end
end
