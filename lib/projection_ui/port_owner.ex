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

  @type state :: %{
          session: GenServer.server(),
          port: port() | nil,
          command: String.t() | nil,
          args: [String.t()],
          env: [{String.t(), String.t()}],
          cd: String.t(),
          reconnect_idx: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec send_envelope(GenServer.server(), map()) :: :ok
  def send_envelope(server, envelope) when is_map(envelope) do
    GenServer.cast(server, {:send_envelope, envelope})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      session: Keyword.fetch!(opts, :session),
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
          Session.handle_ui_envelope(state.session, envelope)
          state

        {:error, reason} ->
          Logger.warning("ui_host inbound decode failed: #{inspect(reason)}")
          state
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

  defp dispatch_to_port(_envelope, %{port: nil} = state), do: state

  defp dispatch_to_port(envelope, %{port: port} = state) do
    case Protocol.encode_outbound(envelope) do
      {:ok, payload} ->
        true = Port.command(port, payload)
        state

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
end
