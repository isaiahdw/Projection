defmodule Projection.HostBridgeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ProjectionUI.HostBridge

  defmodule SessionStub do
    use GenServer

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid)
    end

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_cast({:ui_envelope, envelope}, test_pid) when is_map(envelope) do
      send(test_pid, {:session_envelope, envelope})
      {:noreply, test_pid}
    end
  end

  test "decode failures emit error envelope and trigger ready resync with tracked sid" do
    {:ok, session} = start_supervised({SessionStub, self()})

    {:ok, owner} =
      start_supervised(
        {HostBridge,
         [
           session: session,
           sid: "S1",
           command: "/bin/cat"
         ]}
      )

    port = wait_for_port!(owner)

    # Establish a new sid from a valid inbound message.
    valid_ready = Jason.encode!(%{"t" => "ready", "sid" => "S9", "capabilities" => %{}})
    assert true == Port.command(port, valid_ready)
    assert_receive {:session_envelope, %{"t" => "ready", "sid" => "S9"}}, 1_000

    # Malformed inbound JSON should force a protocol error + ready resync.
    assert true == Port.command(port, "{")

    assert_receive {:session_envelope, %{"t" => "ready", "sid" => "S9"}}, 1_000

    # The emitted error envelope is routed through the cat process and returns inbound.
    assert_receive {:session_envelope,
                    %{"t" => "error", "sid" => "S9", "code" => "decode_error"}},
                   1_000
  end

  test "oversized inbound frame emits frame_too_large error envelope and resync" do
    {:ok, session} = start_supervised({SessionStub, self()})

    {:ok, owner} =
      start_supervised(
        {HostBridge,
         [
           session: session,
           sid: "S2",
           command: "/bin/cat"
         ]}
      )

    port = wait_for_port!(owner)
    huge_payload = String.duplicate("a", Projection.Protocol.ui_to_elixir_cap() + 1)
    assert true == Port.command(port, huge_payload)

    assert_receive {:session_envelope, %{"t" => "ready", "sid" => "S2"}}, 1_000

    assert_receive {:session_envelope,
                    %{"t" => "error", "sid" => "S2", "code" => "frame_too_large"}},
                   1_000
  end

  test "oversized outbound envelope is logged and dropped without crashing host bridge" do
    {:ok, session} = start_supervised({SessionStub, self()})

    {:ok, owner} =
      start_supervised(
        {HostBridge,
         [
           session: session,
           sid: "S3",
           command: "/bin/cat"
         ]}
      )

    _port = wait_for_port!(owner)

    oversized_envelope = %{
      "t" => "render",
      "sid" => "S3",
      "rev" => 1,
      "vm" => %{"payload" => String.duplicate("a", Projection.Protocol.elixir_to_ui_cap())}
    }

    log =
      capture_log(fn ->
        HostBridge.send_envelope(owner, oversized_envelope)
        Process.sleep(50)
      end)

    assert log =~ "ui_host outbound encode failed: :frame_too_large"
    assert Process.alive?(owner)
    refute_receive {:session_envelope, _}, 100
  end

  defp wait_for_port!(owner, attempts \\ 40)

  defp wait_for_port!(owner, attempts) when attempts > 0 do
    case :sys.get_state(owner) do
      %{port: port} when is_port(port) ->
        port

      _ ->
        Process.sleep(25)
        wait_for_port!(owner, attempts - 1)
    end
  end

  defp wait_for_port!(_owner, 0) do
    flunk("port did not become available in time")
  end
end
