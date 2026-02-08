defmodule Projection.SessionTelemetryTest do
  use ExUnit.Case, async: false

  alias Projection.Session

  defmodule FailingRenderScreen do
    use ProjectionUI, :screen

    schema do
      field(:value, :string, default: "ok")
    end

    @impl true
    def render(_assigns) do
      raise "boom from telemetry test render"
    end
  end

  @events [
    [:projection, :session, :intent, :received],
    [:projection, :session, :render, :complete],
    [:projection, :session, :patch, :sent],
    [:projection, :session, :error]
  ]

  test "emits intent, render, and patch telemetry with sid/rev/screen metadata" do
    attach_telemetry_handler!()

    {:ok, session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_module: Projection.TestScreens.Clock,
           host_bridge: self(),
           batch_window_ms: 0
         ]}
      )

    assert_receive {:telemetry, [:projection, :session, :render, :complete], render_meas,
                    render_meta},
                   500

    assert render_meas.count == 1
    assert is_integer(render_meas.duration_native)
    assert render_meta.sid == "S1"
    assert render_meta.rev == 0
    assert is_binary(render_meta.screen)
    assert render_meta.status == :ok

    assert {:ok, [_render]} =
             Session.handle_ui_envelope_sync(session, %{"t" => "ready", "sid" => "S1"})

    assert {:ok, []} =
             Session.handle_ui_envelope_sync(session, %{
               "t" => "intent",
               "sid" => "S1",
               "id" => 10,
               "name" => "clock.pause",
               "payload" => %{}
             })

    assert_receive {:telemetry, [:projection, :session, :intent, :received], intent_meas,
                    intent_meta},
                   500

    assert intent_meas.count == 1
    assert intent_meta.sid == "S1"
    assert intent_meta.rev == 1
    assert intent_meta.intent == "clock.pause"
    assert intent_meta.ack == 10
    assert is_binary(intent_meta.screen)

    assert_receive {:telemetry, [:projection, :session, :patch, :sent], patch_meas, patch_meta},
                   500

    assert patch_meas.count == 1
    assert patch_meas.op_count > 0
    assert patch_meta.sid == "S1"
    assert patch_meta.rev == 2
    assert patch_meta.ack == 10
    assert is_binary(patch_meta.screen)
  end

  test "emits session error telemetry when render raises" do
    attach_telemetry_handler!()

    {:ok, _session} =
      start_supervised(
        {Session,
         [
           sid: "S1",
           screen_module: FailingRenderScreen,
           host_bridge: self()
         ]}
      )

    assert_receive {:telemetry, [:projection, :session, :error], meas, metadata}, 500
    assert meas.count == 1
    assert metadata.kind == :render_exception
    assert metadata.screen == "Projection.SessionTelemetryTest.FailingRenderScreen"
    assert metadata.error == "boom from telemetry test render"
  end

  defp attach_telemetry_handler! do
    test_pid = self()
    handler_id = "projection-session-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)
  end
end
