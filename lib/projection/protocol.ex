defmodule Projection.Protocol do
  @moduledoc """
  JSON envelope helpers and cap enforcement for Projection port traffic.

  Notes:
  - OTP `{:packet, 4}` handles length framing at the port boundary.
  - This module is responsible for JSON encoding/decoding and payload caps.
  """

  @ui_to_elixir_cap 65_536
  @elixir_to_ui_cap 1_048_576

  @type envelope :: map()

  @spec ui_to_elixir_cap() :: pos_integer()
  def ui_to_elixir_cap, do: @ui_to_elixir_cap

  @spec elixir_to_ui_cap() :: pos_integer()
  def elixir_to_ui_cap, do: @elixir_to_ui_cap

  @spec decode_inbound(binary()) :: {:ok, envelope()} | {:error, atom()}
  def decode_inbound(payload) when is_binary(payload) do
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

  @spec encode_outbound(envelope()) :: {:ok, binary()} | {:error, atom()}
  def encode_outbound(envelope) when is_map(envelope) do
    with {:ok, payload} <- Jason.encode(envelope),
         :ok <- validate_outbound_size(payload) do
      {:ok, payload}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :encode_error}
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  @spec render_envelope(String.t(), non_neg_integer(), map(), keyword()) :: envelope()
  def render_envelope(sid, rev, vm, opts \\ []) do
    base = %{"t" => "render", "sid" => sid, "rev" => rev, "vm" => vm}

    case Keyword.fetch(opts, :ack) do
      {:ok, ack} -> Map.put(base, "ack", ack)
      :error -> base
    end
  end

  @spec patch_envelope(String.t(), non_neg_integer(), [map()], keyword()) :: envelope()
  def patch_envelope(sid, rev, ops, opts \\ []) when is_list(ops) do
    base = %{"t" => "patch", "sid" => sid, "rev" => rev, "ops" => ops}

    case Keyword.fetch(opts, :ack) do
      {:ok, ack} -> Map.put(base, "ack", ack)
      :error -> base
    end
  end

  @spec error_envelope(String.t(), non_neg_integer() | nil, String.t(), String.t()) :: envelope()
  def error_envelope(sid, rev, code, message) do
    envelope = %{"t" => "error", "sid" => sid, "code" => code, "message" => message}

    if is_nil(rev), do: envelope, else: Map.put(envelope, "rev", rev)
  end

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
end
