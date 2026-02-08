defmodule Projection.Protocol do
  @moduledoc """
  JSON envelope helpers and cap enforcement for Projection port traffic.

  Notes:
  - OTP `{:packet, 4}` handles length framing at the port boundary.
  - This module is responsible for JSON encoding/decoding and payload caps.
  """

  require Logger

  @ui_to_elixir_cap 65_536
  @elixir_to_ui_cap 1_048_576
  @warn_threshold_percent 80

  @typedoc "A JSON-serializable map representing a protocol envelope."
  @type envelope :: map()

  @doc "Maximum payload size (bytes) accepted from the UI host."
  @spec ui_to_elixir_cap() :: pos_integer()
  def ui_to_elixir_cap, do: @ui_to_elixir_cap

  @doc "Maximum payload size (bytes) sent to the UI host."
  @spec elixir_to_ui_cap() :: pos_integer()
  def elixir_to_ui_cap, do: @elixir_to_ui_cap

  @doc """
  Decodes a binary payload received from the UI host.

  Returns `{:error, :frame_too_large}` if the payload exceeds `ui_to_elixir_cap/0`,
  or `{:error, :decode_error}` if JSON parsing fails.
  """
  @spec decode_inbound(binary()) :: {:ok, envelope()} | {:error, atom()}
  def decode_inbound(payload) when is_binary(payload) do
    maybe_warn_frame_size(:ui_to_elixir, byte_size(payload), @ui_to_elixir_cap)

    if byte_size(payload) > @ui_to_elixir_cap do
      {:error, :frame_too_large}
    else
      case Jason.decode(payload) do
        {:ok, envelope} when is_map(envelope) -> {:ok, envelope}
        {:ok, _not_envelope} -> {:error, :invalid_envelope}
        {:error, _reason} -> {:error, :decode_error}
      end
    end
  end

  @doc """
  Encodes an envelope map to a JSON binary for the UI host.

  Returns `{:error, :frame_too_large}` if the encoded payload exceeds
  `elixir_to_ui_cap/0`.
  """
  @spec encode_outbound(envelope()) :: {:ok, binary()} | {:error, atom()}
  def encode_outbound(envelope) when is_map(envelope) do
    with {:ok, payload} <- Jason.encode(envelope),
         :ok <- maybe_warn_frame_size(:elixir_to_ui, byte_size(payload), @elixir_to_ui_cap),
         :ok <- validate_outbound_size(payload) do
      {:ok, payload}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :encode_error}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  @doc """
  Builds a `render` envelope containing a full view-model snapshot.

  Accepts an optional `:ack` in `opts` to acknowledge the intent that
  triggered this render.
  """
  @spec render_envelope(String.t(), non_neg_integer(), map(), keyword()) :: envelope()
  def render_envelope(sid, rev, vm, opts \\ []) do
    base = %{"t" => "render", "sid" => sid, "rev" => rev, "vm" => vm}

    case Keyword.fetch(opts, :ack) do
      {:ok, ack} -> Map.put(base, "ack", ack)
      :error -> base
    end
  end

  @doc """
  Builds a `patch` envelope containing RFC 6902 ops and a new revision.

  Accepts an optional `:ack` in `opts` to acknowledge the intent that
  triggered this patch.
  """
  @spec patch_envelope(String.t(), non_neg_integer(), [map()], keyword()) :: envelope()
  def patch_envelope(sid, rev, ops, opts \\ []) when is_list(ops) do
    base = %{"t" => "patch", "sid" => sid, "rev" => rev, "ops" => ops}

    case Keyword.fetch(opts, :ack) do
      {:ok, ack} -> Map.put(base, "ack", ack)
      :error -> base
    end
  end

  @doc "Builds an `error` envelope. Pass `nil` for `rev` if no revision applies."
  @spec error_envelope(String.t(), non_neg_integer() | nil, String.t(), String.t()) :: envelope()
  def error_envelope(sid, rev, code, message) do
    envelope = %{"t" => "error", "sid" => sid, "code" => code, "message" => message}

    if is_nil(rev), do: envelope, else: Map.put(envelope, "rev", rev)
  end

  @doc "Returns `true` if the envelope is a valid `ready` handshake."
  @spec ready?(envelope()) :: boolean()
  def ready?(%{"t" => "ready", "sid" => sid}) when is_binary(sid), do: true
  def ready?(_), do: false

  defp validate_outbound_size(payload) do
    if byte_size(payload) > @elixir_to_ui_cap do
      {:error, :frame_too_large}
    else
      :ok
    end
  end

  defp maybe_warn_frame_size(direction, size, cap) when is_integer(size) and is_integer(cap) do
    if size <= cap and size * 100 >= cap * @warn_threshold_percent do
      Logger.warning(
        "protocol frame size nearing cap direction=#{direction} size=#{size} cap=#{cap} threshold=#{@warn_threshold_percent}%"
      )
    end

    :ok
  end
end
