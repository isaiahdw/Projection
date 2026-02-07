defmodule Projection.Patch do
  @moduledoc """
  JSON Patch helpers for Projection.

  Supports the RFC6902 subset used by Projection (`add`, `remove`, `replace`)
  plus RFC6901 token escaping helpers for pointer paths.
  """

  @type op :: map()

  @spec replace(String.t(), any()) :: op()
  def replace(path, value) when is_binary(path) do
    %{"op" => "replace", "path" => path, "value" => value}
  end

  @spec add(String.t(), any()) :: op()
  def add(path, value) when is_binary(path) do
    %{"op" => "add", "path" => path, "value" => value}
  end

  @spec remove(String.t()) :: op()
  def remove(path) when is_binary(path) do
    %{"op" => "remove", "path" => path}
  end

  @spec pointer([String.t()]) :: String.t()
  def pointer(tokens) when is_list(tokens) do
    "/" <> Enum.map_join(tokens, "/", &escape_token/1)
  end

  @spec escape_token(String.t()) :: String.t()
  def escape_token(token) when is_binary(token) do
    token
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end
end
