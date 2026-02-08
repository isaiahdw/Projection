mod generated;
mod patch_apply;
mod protocol;

use crate::protocol::{
    ElixirEnvelope, UiEnvelope, intent_envelope, reader_loop, ready_envelope, writer_loop,
};
use serde_json::Value;
use serde_json::json;
use slint::ComponentHandle;
use std::process;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread;

slint::include_modules!();

const DEFAULT_UI_OUTBOUND_QUEUE_CAP: usize = 256;

fn main() {
    if let Err(err) = run() {
        eprintln!("ui_host fatal error: {err}");
        process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let ui = AppWindow::new()?;
    let ui_weak = ui.as_weak();
    let ui_model_state = Arc::new(Mutex::new(patch_apply::UiModelState::default()));
    let next_intent_id = Arc::new(AtomicU64::new(1));
    let dropped_intent_count = Arc::new(AtomicU64::new(0));
    let resync_pending = Arc::new(AtomicBool::new(false));
    let outbound_queue_cap = parse_outbound_queue_capacity();
    let (tx, rx) = mpsc::sync_channel(outbound_queue_cap);
    let sid = std::env::var("PROJECTION_SID").unwrap_or_else(|_| "S1".to_string());
    let resync_tx = tx.clone();
    let resync_sid = sid.clone();
    let resync_flag = resync_pending.clone();
    install_callbacks(
        &ui,
        tx.clone(),
        sid.clone(),
        next_intent_id,
        dropped_intent_count,
        outbound_queue_cap,
    );

    let writer_handle = thread::spawn(move || writer_loop(rx));

    tx.send(ready_envelope(sid))
        .map_err(|_| "failed to queue ready envelope")?;

    let reader_handle = thread::spawn(move || {
        let shared_state = ui_model_state.clone();
        let read_result = reader_loop(|envelope| match envelope {
            ElixirEnvelope::Render { sid, rev, vm } => {
                let state_for_render = shared_state.clone();
                let tx_for_resync = resync_tx.clone();
                let sid_for_resync = resync_sid.clone();
                let resync_pending_for_render = resync_flag.clone();
                let _ = ui_weak.upgrade_in_event_loop(move |ui| {
                    let Ok(mut state) = state_for_render.lock() else {
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "failed to lock UI model state for render",
                            &resync_pending_for_render,
                            outbound_queue_cap,
                        );
                        return;
                    };

                    if sid != sid_for_resync {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "sid mismatch for render envelope",
                            &resync_pending_for_render,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    if let Err(err) = patch_apply::validate_render_rev(&state, rev) {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("invalid render revision: {err}"),
                            &resync_pending_for_render,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    if let Err(err) = patch_apply::apply_render(&ui, &vm, &mut state) {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("render apply failed: {err}"),
                            &resync_pending_for_render,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    patch_apply::mark_applied_rev(&mut state, rev);
                    resync_pending_for_render.store(false, Ordering::Release);
                });
            }
            ElixirEnvelope::Patch { sid, rev, ack, ops } => {
                let tx_for_resync = resync_tx.clone();
                let sid_for_resync = resync_sid.clone();
                let state_for_patch = shared_state.clone();
                let resync_pending_for_patch = resync_flag.clone();

                let _ = ui_weak.upgrade_in_event_loop(move |ui| {
                    let Ok(mut state) = state_for_patch.lock() else {
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "failed to lock UI model state for patch",
                            &resync_pending_for_patch,
                            outbound_queue_cap,
                        );
                        return;
                    };

                    if sid != sid_for_resync {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "sid mismatch for patch envelope",
                            &resync_pending_for_patch,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    if let Err(err) = patch_apply::validate_patch_rev(&state, rev) {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("invalid patch revision: {err}"),
                            &resync_pending_for_patch,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    if let Err(err) = patch_apply::apply_patch(&ui, &ops, &mut state) {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("patch apply failed: {err}"),
                            &resync_pending_for_patch,
                            outbound_queue_cap,
                        );
                        return;
                    }

                    patch_apply::mark_applied_rev(&mut state, rev);
                    patch_apply::mark_applied_ack(&mut state, ack);
                });
            }
            ElixirEnvelope::Error {
                sid,
                rev,
                code,
                message,
            } => {
                eprintln!("server error sid={sid} rev={rev:?}: {code}: {message}");
                if should_resync_for_error(&code) {
                    request_resync(
                        &resync_tx,
                        &resync_sid,
                        &format!("server requested resync via error code '{code}'"),
                        &resync_flag,
                        outbound_queue_cap,
                    );
                }
            }
        });

        if let Err(err) = &read_result {
            eprintln!("reader loop terminated with error: {err}");
        }

        let quit_result = slint::invoke_from_event_loop(|| {
            let _ = slint::quit_event_loop();
        });

        if let Err(err) = quit_result {
            eprintln!("failed to request UI event loop quit: {err}");
        }

        read_result
    });

    ui.run()?;

    // Drop UI first so callback closures release their `tx` clones.
    drop(ui);
    drop(tx);

    if reader_handle.is_finished() {
        match reader_handle.join() {
            Ok(Ok(())) => {}
            Ok(Err(err)) => eprintln!("reader thread returned error: {err}"),
            Err(err) => eprintln!("reader thread join failed: {err:?}"),
        }
    } else {
        // Avoid hanging process exit on a blocked stdio read during teardown.
        eprintln!("reader thread still active during shutdown; skipping join");
    }

    if writer_handle.is_finished() {
        match writer_handle.join() {
            Ok(Ok(())) => {}
            Ok(Err(err)) => eprintln!("writer thread returned error: {err}"),
            Err(err) => eprintln!("writer thread join failed: {err:?}"),
        }
    } else {
        // Avoid hanging process exit on a blocked stdio write during teardown.
        eprintln!("writer thread still active during shutdown; skipping join");
    }

    Ok(())
}

fn install_callbacks(
    ui: &AppWindow,
    tx: SyncSender<UiEnvelope>,
    sid: String,
    next_intent_id: Arc<AtomicU64>,
    dropped_intent_count: Arc<AtomicU64>,
    queue_capacity: usize,
) {
    let bridge_tx = tx.clone();
    let bridge_sid = sid.clone();
    let bridge_next_id = next_intent_id.clone();
    let bridge_drop_count = dropped_intent_count.clone();
    let bridge = ui.global::<UI>();
    bridge.on_intent(move |intent_name, intent_arg| {
        let name = intent_name.to_string();

        if name.is_empty() {
            return;
        }

        let payload = if intent_arg.is_empty() {
            json!({})
        } else {
            json!({ "arg": intent_arg.to_string() })
        };

        send_intent(
            &bridge_tx,
            bridge_sid.clone(),
            &bridge_next_id,
            &name,
            payload,
            &bridge_drop_count,
            queue_capacity,
        );
    });

    let intent_tx = tx.clone();
    let intent_sid = sid.clone();
    let intent_next_id = next_intent_id.clone();
    let intent_drop_count = dropped_intent_count.clone();
    ui.on_ui_intent(move |intent_name, intent_arg| {
        let name = intent_name.to_string();

        if name.is_empty() {
            return;
        }

        let payload = if intent_arg.is_empty() {
            json!({})
        } else {
            json!({ "arg": intent_arg.to_string() })
        };

        send_intent(
            &intent_tx,
            intent_sid.clone(),
            &intent_next_id,
            &name,
            payload,
            &intent_drop_count,
            queue_capacity,
        );
    });

    let navigate_tx = tx.clone();
    let navigate_sid = sid.clone();
    let navigate_intent_id = next_intent_id.clone();
    let navigate_drop_count = dropped_intent_count.clone();
    ui.on_navigate(move |route_name, params_json| {
        let to = route_name.to_string();

        if to.is_empty() {
            return;
        }

        let params_raw = params_json.to_string();
        let params = parse_params_json(&params_raw);
        let payload = json!({ "to": to, "params": params });

        send_intent(
            &navigate_tx,
            navigate_sid.clone(),
            &navigate_intent_id,
            "ui.route.navigate",
            payload,
            &navigate_drop_count,
            queue_capacity,
        );
    });
}

fn send_intent(
    tx: &SyncSender<UiEnvelope>,
    sid: String,
    next_intent_id: &AtomicU64,
    name: &str,
    payload: serde_json::Value,
    dropped_intent_count: &AtomicU64,
    queue_capacity: usize,
) {
    let id = next_intent_id.fetch_add(1, Ordering::Relaxed);
    let envelope = intent_envelope(sid, id, name.to_string(), payload);

    match tx.try_send(envelope) {
        Ok(()) => {}
        Err(TrySendError::Full(_envelope)) => {
            let dropped = dropped_intent_count.fetch_add(1, Ordering::Relaxed) + 1;
            if dropped == 1 || dropped.is_power_of_two() {
                eprintln!(
                    "ui intent queue full (cap={queue_capacity}); dropped {dropped} intent(s)"
                );
            }
        }
        Err(TrySendError::Disconnected(_envelope)) => {
            eprintln!("failed to queue UI intent: {name}");
        }
    }
}

fn request_resync(
    tx: &SyncSender<UiEnvelope>,
    sid: &str,
    reason: &str,
    resync_pending: &AtomicBool,
    queue_capacity: usize,
) {
    if resync_pending
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return;
    }

    eprintln!("{reason}; requesting resync");

    enqueue_control_envelope(tx.clone(), ready_envelope(sid.to_string()), queue_capacity);
}

fn parse_params_json(raw: &str) -> Value {
    if raw.is_empty() {
        return json!({});
    }

    match serde_json::from_str::<Value>(raw) {
        Ok(Value::Object(map)) => Value::Object(map),
        Ok(_) => json!({}),
        Err(_) => json!({}),
    }
}

fn enqueue_control_envelope(
    tx: SyncSender<UiEnvelope>,
    envelope: UiEnvelope,
    queue_capacity: usize,
) {
    match tx.try_send(envelope) {
        Ok(()) => {}
        Err(TrySendError::Full(envelope)) => {
            eprintln!(
                "ui outbound queue full (cap={queue_capacity}); waiting to enqueue control envelope"
            );
            thread::spawn(move || {
                if tx.send(envelope).is_err() {
                    eprintln!("failed to enqueue control envelope");
                }
            });
        }
        Err(TrySendError::Disconnected(_envelope)) => {
            eprintln!("failed to enqueue control envelope");
        }
    }
}

fn should_resync_for_error(code: &str) -> bool {
    matches!(
        code,
        "decode_error"
            | "frame_too_large"
            | "invalid_envelope"
            | "resync_required"
            | "rev_mismatch"
            | "patch_apply_error"
    )
}

fn parse_outbound_queue_capacity() -> usize {
    std::env::var("PROJECTION_UI_OUTBOUND_QUEUE_CAP")
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_UI_OUTBOUND_QUEUE_CAP)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn send_intent_drops_when_queue_is_full() {
        let (tx, rx) = mpsc::sync_channel(1);
        let next_intent_id = AtomicU64::new(1);
        let dropped = AtomicU64::new(0);

        tx.send(ready_envelope("S1".to_string()))
            .expect("seed queue with one envelope");

        send_intent(
            &tx,
            "S1".to_string(),
            &next_intent_id,
            "clock.pause",
            json!({}),
            &dropped,
            1,
        );

        assert_eq!(dropped.load(Ordering::Relaxed), 1);

        let seeded = rx.try_recv().expect("seed envelope remains queued");
        match seeded {
            UiEnvelope::Ready { sid, .. } => assert_eq!(sid, "S1"),
            other => panic!("expected ready envelope, got {other:?}"),
        }
    }

    #[test]
    fn resync_error_codes_are_explicit() {
        assert!(should_resync_for_error("decode_error"));
        assert!(should_resync_for_error("frame_too_large"));
        assert!(should_resync_for_error("invalid_envelope"));
        assert!(should_resync_for_error("resync_required"));
        assert!(!should_resync_for_error("validation_warning"));
    }
}
