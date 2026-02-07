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
    %{"op" => "replace", "path" => path, "value" => value}
  end

  @doc "Builds an `add` op for the given JSON Pointer `path`."
  @spec add(String.t(), any()) :: op()
  def add(path, value) when is_binary(path) do
    %{"op" => "add", "path" => path, "value" => value}
  end

  @doc "Builds a `remove` op for the given JSON Pointer `path`."
  @spec remove(String.t()) :: op()
  def remove(path) when is_binary(path) do
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
end
