defmodule ProjectionUI.PortOwner do
  @moduledoc """
  Owns the external UI host port process and forwards envelopes between
  the host and `Projection.Session`.

  M1 behavior:
  - decode inbound JSON envelopes from the port
  - forward to `Projection.Session`
  - encode outbound envelopes back to the port
  - reconnect using bounded exponential backoff
  """

  use GenServer

  require Logger

  alias Projection.Session
  alias Projection.Protocol

  @backoff_steps_ms [100, 200, 500, 1_000, 2_000, 5_000]

  @typedoc "Internal state for the port owner process."
  @type state :: %{
          session: GenServer.server(),
          sid: String.t(),
          port: port() | nil,
          command: String.t() | nil,
          args: [String.t()],
          env: [{String.t(), String.t()}],
          cd: String.t(),
          reconnect_idx: non_neg_integer()
        }

  @doc """
  Starts the port owner linked to the caller.

  ## Options

    * `:name` — registered process name
    * `:session` — (required) name or pid of the `Projection.Session` to forward envelopes to
    * `:command` — path to the UI host executable (nil keeps the port disconnected)
    * `:args` — command-line arguments for the host binary
    * `:env` — list of `{key, value}` environment variable tuples
    * `:cd` — working directory for the host process

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Sends an outbound envelope to the UI host port. Silently drops if the port is down."
  @spec send_envelope(GenServer.server(), map()) :: :ok
  def send_envelope(server, envelope) when is_map(envelope) do
    GenServer.cast(server, {:send_envelope, envelope})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      session: Keyword.fetch!(opts, :session),
      sid: normalize_sid(Keyword.get(opts, :sid, "S1")),
      port: nil,
      command: Keyword.get(opts, :command),
      args: Keyword.get(opts, :args, []),
      env: Keyword.get(opts, :env, []),
      cd: Keyword.get(opts, :cd, File.cwd!()),
      reconnect_idx: 0
    }

    {:ok, maybe_connect(state)}
  end

  @impl true
  def handle_cast({:send_envelope, envelope}, state) do
    {:noreply, dispatch_to_port(envelope, state)}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, maybe_connect(state)}
  end

  def handle_info({port, {:data, payload}}, %{port: port} = state) when is_binary(payload) do
    next_state =
      case Protocol.decode_inbound(payload) do
        {:ok, envelope} ->
          next_state = maybe_track_sid_from_envelope(envelope, state)
          Session.handle_ui_envelope(state.session, envelope)
          next_state

        {:error, reason} ->
          Logger.warning("ui_host inbound decode failed: #{inspect(reason)}")
          handle_decode_error(reason, state)
      end

    {:noreply, next_state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("ui_host exited with status #{status}; scheduling reconnect")
    {:noreply, schedule_reconnect(%{state | port: nil})}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("ui_host port exit #{inspect(reason)}; scheduling reconnect")
    {:noreply, schedule_reconnect(%{state | port: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    try do
      Port.close(port)
    catch
      :error, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp dispatch_to_port(envelope, %{port: nil} = state) do
    maybe_track_sid_from_envelope(envelope, state)
  end

  defp dispatch_to_port(envelope, %{port: port} = state) do
    case Protocol.encode_outbound(envelope) do
      {:ok, payload} ->
        true = Port.command(port, payload)
        maybe_track_sid_from_envelope(envelope, state)

      {:error, reason} ->
        Logger.warning("ui_host outbound encode failed: #{inspect(reason)}")
        state
    end
  end

  defp maybe_connect(%{command: nil} = state) do
    Logger.debug("ProjectionUI.PortOwner started without :command; port remains disconnected")
    state
  end

  defp maybe_connect(state) do
    try do
      port =
        Port.open(
          {:spawn_executable, state.command},
          [
            :binary,
            {:packet, 4},
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args: state.args,
            env: normalize_env(state.env),
            cd: state.cd
          ]
        )

      %{state | port: port, reconnect_idx: 0}
    rescue
      error ->
        Logger.warning("failed to start ui_host: #{Exception.message(error)}")
        schedule_reconnect(state)
    end
  end

  defp schedule_reconnect(%{command: nil} = state), do: state

  defp schedule_reconnect(state) do
    idx = min(state.reconnect_idx, length(@backoff_steps_ms) - 1)
    base = Enum.at(@backoff_steps_ms, idx)
    jitter = :rand.uniform(max(div(base, 10), 1)) - 1
    delay = base + jitter

    Process.send_after(self(), :reconnect, delay)

    %{state | reconnect_idx: min(idx + 1, length(@backoff_steps_ms) - 1)}
  end

  defp normalize_env(env) do
    Enum.map(env, fn {key, value} ->
      {to_charlist(key), to_charlist(value)}
    end)
  end

  defp handle_decode_error(reason, state) do
    {code, message} = decode_error_details(reason)

    state = dispatch_to_port(Protocol.error_envelope(state.sid, nil, code, message), state)

    Session.handle_ui_envelope(state.session, %{"t" => "ready", "sid" => state.sid})
    state
  end

  defp decode_error_details(:frame_too_large),
    do: {"frame_too_large", "inbound frame exceeds ui_to_elixir cap"}

  defp decode_error_details(:decode_error),
    do: {"decode_error", "malformed inbound json payload"}

  defp decode_error_details(:invalid_envelope),
    do: {"invalid_envelope", "inbound payload must decode to a json object"}

  defp decode_error_details(other),
    do: {"decode_error", "inbound decode failed: #{inspect(other)}"}

  defp maybe_track_sid_from_envelope(%{"sid" => sid}, state) when is_binary(sid) and sid != "" do
    %{state | sid: sid}
  end

  defp maybe_track_sid_from_envelope(_envelope, state), do: state

  defp normalize_sid(sid) when is_binary(sid) and sid != "", do: sid
  defp normalize_sid(_sid), do: "S1"
end
