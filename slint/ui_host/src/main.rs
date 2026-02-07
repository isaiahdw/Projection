mod generated;
mod patch_apply;
mod protocol;

use crate::protocol::{
    ElixirEnvelope, UiEnvelope, intent_envelope, reader_loop, ready_envelope, writer_loop,
};
use serde_json::Value;
use serde_json::json;
use std::process;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;

slint::include_modules!();

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

    let (tx, rx) = mpsc::channel();
    let sid = std::env::var("PROJECTION_SID").unwrap_or_else(|_| "S1".to_string());
    let resync_tx = tx.clone();
    let resync_sid = sid.clone();
    install_callbacks(
        &ui,
        tx.clone(),
        sid.clone(),
        next_intent_id,
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
                let _ = ui_weak.upgrade_in_event_loop(move |ui| {
                    let Ok(mut state) = state_for_render.lock() else {
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "failed to lock UI model state for render",
                        );
                        return;
                    };

                    if sid != sid_for_resync {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "sid mismatch for render envelope",
                        );
                        return;
                    }

                    if let Err(err) = patch_apply::validate_render_rev(&state, rev) {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("invalid render revision: {err}"),
                        );
                        return;
                    }

                    if let Err(err) = patch_apply::apply_render(&ui, &vm, &mut state) {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("render apply failed: {err}"),
                        );
                        return;
                    }

                    patch_apply::mark_applied_rev(&mut state, rev);
                });
            }
            ElixirEnvelope::Patch { sid, rev, ack, ops } => {
                let _ = ack;
                let tx_for_resync = resync_tx.clone();
                let sid_for_resync = resync_sid.clone();
                let state_for_patch = shared_state.clone();

                let _ = ui_weak.upgrade_in_event_loop(move |ui| {
                    let Ok(mut state) = state_for_patch.lock() else {
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "failed to lock UI model state for patch",
                        );
                        return;
                    };

                    if sid != sid_for_resync {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            "sid mismatch for patch envelope",
                        );
                        return;
                    }

                    if let Err(err) = patch_apply::validate_patch_rev(&state, rev) {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("invalid patch revision: {err}"),
                        );
                        return;
                    }

                    if let Err(err) = patch_apply::apply_patch(&ui, &ops, &mut state) {
                        patch_apply::reset_for_resync(&mut state);
                        request_resync(
                            &tx_for_resync,
                            &sid_for_resync,
                            &format!("patch apply failed: {err}"),
                        );
                        return;
                    }

                    patch_apply::mark_applied_rev(&mut state, rev);
                });
            }
            ElixirEnvelope::Error {
                sid,
                rev,
                code,
                message,
            } => {
                eprintln!("server error sid={sid} rev={rev:?}: {code}: {message}");
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
    tx: mpsc::Sender<UiEnvelope>,
    sid: String,
    next_intent_id: Arc<AtomicU64>,
) {
    let intent_tx = tx.clone();
    let intent_sid = sid.clone();
    let intent_next_id = next_intent_id.clone();
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
        );
    });

    let navigate_tx = tx.clone();
    let navigate_sid = sid.clone();
    let navigate_intent_id = next_intent_id.clone();
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
        );
    });

}

fn send_intent(
    tx: &mpsc::Sender<UiEnvelope>,
    sid: String,
    next_intent_id: &AtomicU64,
    name: &str,
    payload: serde_json::Value,
) {
    let id = next_intent_id.fetch_add(1, Ordering::Relaxed);

    if tx
        .send(intent_envelope(sid, id, name.to_string(), payload))
        .is_err()
    {
        eprintln!("failed to queue UI intent: {name}");
    }
}

fn request_resync(tx: &mpsc::Sender<UiEnvelope>, sid: &str, reason: &str) {
    eprintln!("{reason}; requesting resync");

    if tx.send(ready_envelope(sid.to_string())).is_err() {
        eprintln!("failed to queue ready envelope for resync");
    }
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
