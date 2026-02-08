defmodule Projection.PatchTest do
  use ExUnit.Case, async: true

  doctest Projection.Patch

  alias Projection.Patch

  test "parse_pointer rejects invalid escape sequences" do
    assert {:error, :invalid_escape} = Patch.parse_pointer("/screen/~2")
    assert {:error, :invalid_escape} = Patch.parse_pointer("/screen/~")
  end

  test "parse_pointer rejects non-pointer paths" do
    assert {:error, :invalid_pointer} = Patch.parse_pointer("screen/vm")
  end

  test "patch op builders reject invalid pointer paths" do
    assert_raise ArgumentError, ~r/invalid JSON pointer path/, fn ->
      Patch.replace("/screen/~2", "bad")
    end
  end
end
