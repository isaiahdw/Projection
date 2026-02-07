defmodule ProjectionUI.Components.StatusBadge do
  @moduledoc """
  Reusable status badge component schema.
  """

  use ProjectionUI, :component

  schema do
    field(:label, :string, default: "")
    field(:status, :string, default: "ok")
  end
end
