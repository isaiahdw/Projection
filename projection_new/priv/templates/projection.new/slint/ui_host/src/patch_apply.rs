use crate::AppWindow;
use crate::generated::{self, ScreenId};
use crate::protocol::PatchOp;
use serde_json::Value;
use slint::ComponentHandle;

#[derive(Debug, Clone)]
pub struct UiModelState {
    pub screen_id: ScreenId,
    pub vm: Value,
    pub last_rev: Option<u64>,
    pub last_ack: Option<u64>,
}

impl Default for UiModelState {
    fn default() -> Self {
        Self {
            screen_id: ScreenId::default(),
            vm: Value::Object(serde_json::Map::new()),
            last_rev: None,
            last_ack: None,
        }
    }
}

pub fn apply_render(
    ui: &AppWindow,
    vm: &Value,
    ui_model_state: &mut UiModelState,
) -> Result<(), String> {
    ui_model_state.vm = vm.clone();
    apply_global_props(ui, &ui_model_state.vm);
    let screen_id = generated::apply_render(ui, vm)?;
    ui_model_state.screen_id = screen_id;
    Ok(())
}

pub fn apply_patch(
    ui: &AppWindow,
    ops: &[PatchOp],
    ui_model_state: &mut UiModelState,
) -> Result<(), String> {
    apply_vm_patch_ops(&mut ui_model_state.vm, ops)?;
    apply_global_props(ui, &ui_model_state.vm);

    if patch_changes_screen(ops) {
        let screen_id = generated::apply_render(ui, &ui_model_state.vm)?;
        ui_model_state.screen_id = screen_id;
        Ok(())
    } else {
        generated::apply_patch(ui, ui_model_state.screen_id, ops, &ui_model_state.vm)
    }
}

pub fn validate_render_rev(state: &UiModelState, rev: u64) -> Result<(), String> {
    match state.last_rev {
        Some(last_rev) if rev == last_rev.wrapping_add(1) => Ok(()),
        Some(last_rev) => Err(format!(
            "render revision mismatch: rev={rev}, expected={}",
            last_rev.wrapping_add(1)
        )),
        None => Ok(()),
    }
}

pub fn validate_patch_rev(state: &UiModelState, rev: u64) -> Result<(), String> {
    match state.last_rev {
        Some(last_rev) if rev == last_rev.wrapping_add(1) => Ok(()),
        Some(last_rev) => Err(format!(
            "patch revision mismatch: rev={rev}, expected={}",
            last_rev.wrapping_add(1)
        )),
        None => Err(format!(
            "patch received before initial render: rev={rev}, expected initial render"
        )),
    }
}

pub fn mark_applied_rev(state: &mut UiModelState, rev: u64) {
    state.last_rev = Some(rev);
}

pub fn mark_applied_ack(state: &mut UiModelState, ack: Option<u64>) {
    match (state.last_ack, ack) {
        (_current, None) => {}
        (None, Some(next_ack)) => state.last_ack = Some(next_ack),
        (Some(current_ack), Some(next_ack)) => state.last_ack = Some(current_ack.max(next_ack)),
    }
}

pub fn reset_for_resync(state: &mut UiModelState) {
    *state = UiModelState::default();
}

fn apply_global_props(ui: &AppWindow, vm: &Value) {
    let app_title = vm
        .pointer("/app/title")
        .and_then(Value::as_str)
        .unwrap_or("Projection");
    ui.set_app_title(app_title.into());

    let active_screen = vm
        .pointer("/screen/name")
        .and_then(Value::as_str)
        .unwrap_or("error");
    ui.set_active_screen(active_screen.into());

    let nav_can_back = vm
        .pointer("/nav/stack")
        .and_then(Value::as_array)
        .map(|stack| stack.len() > 1)
        .unwrap_or(false);
    ui.set_nav_can_back(nav_can_back);

    let error_title = vm
        .pointer("/screen/vm/title")
        .and_then(Value::as_str)
        .unwrap_or("");
    let error_state = ui.global::<crate::ErrorState>();
    error_state.set_error_title(error_title.into());

    let error_message = vm
        .pointer("/screen/vm/message")
        .and_then(Value::as_str)
        .unwrap_or("");
    error_state.set_error_message(error_message.into());

    let error_screen_module = vm
        .pointer("/screen/vm/screen_module")
        .and_then(Value::as_str)
        .unwrap_or("");
    error_state.set_error_screen_module(error_screen_module.into());
}

fn patch_changes_screen(ops: &[PatchOp]) -> bool {
    ops.iter().any(|op| match op {
        PatchOp::Replace { path, .. } | PatchOp::Add { path, .. } | PatchOp::Remove { path } => {
            path == "/screen/name"
        }
    })
}

fn apply_vm_patch_ops(vm: &mut Value, ops: &[PatchOp]) -> Result<(), String> {
    for op in ops {
        match op {
            PatchOp::Replace { path, value } => set_path(vm, path, value.clone(), true)?,
            PatchOp::Add { path, value } => set_path(vm, path, value.clone(), false)?,
            PatchOp::Remove { path } => remove_path(vm, path)?,
        }
    }

    Ok(())
}

fn set_path(root: &mut Value, path: &str, value: Value, replace_only: bool) -> Result<(), String> {
    let tokens = parse_pointer(path)?;

    if tokens.is_empty() {
        *root = value;
        return Ok(());
    }

    let mut current = root;

    for token in &tokens[..tokens.len() - 1] {
        current = descend_or_create(current, token)?;
    }

    let last = tokens.last().expect("tokens not empty");

    match current {
        Value::Object(map) => {
            if replace_only && !map.contains_key(last) {
                return Err(format!("replace path does not exist: {path}"));
            }

            map.insert(last.clone(), value);
            Ok(())
        }
        Value::Array(items) => {
            let index = parse_index(last, items.len(), path)?;

            if index == items.len() {
                items.push(value);
            } else {
                items[index] = value;
            }

            Ok(())
        }
        _ => Err(format!("cannot set path on non-container parent: {path}")),
    }
}

fn remove_path(root: &mut Value, path: &str) -> Result<(), String> {
    let tokens = parse_pointer(path)?;

    if tokens.is_empty() {
        *root = Value::Object(serde_json::Map::new());
        return Ok(());
    }

    let mut current = root;

    for token in &tokens[..tokens.len() - 1] {
        current = descend_existing(current, token)
            .ok_or_else(|| format!("remove path does not exist: {path}"))?;
    }

    let last = tokens.last().expect("tokens not empty");

    match current {
        Value::Object(map) => {
            if map.remove(last).is_some() {
                Ok(())
            } else {
                Err(format!("remove path does not exist: {path}"))
            }
        }
        Value::Array(items) => {
            let index = parse_index(last, items.len().saturating_sub(1), path)?;

            if index < items.len() {
                items.remove(index);
                Ok(())
            } else {
                Err(format!("remove path index out of bounds: {path}"))
            }
        }
        _ => Err(format!(
            "cannot remove path on non-container parent: {path}"
        )),
    }
}

fn parse_pointer(path: &str) -> Result<Vec<String>, String> {
    if path.is_empty() {
        return Ok(vec![]);
    }

    if !path.starts_with('/') {
        return Err(format!("invalid json pointer path: {path}"));
    }

    path.split('/')
        .skip(1)
        .map(unescape_json_pointer_token)
        .collect()
}

fn unescape_json_pointer_token(token: &str) -> Result<String, String> {
    let mut out = String::with_capacity(token.len());
    let mut chars = token.chars();

    while let Some(ch) = chars.next() {
        if ch == '~' {
            match chars.next() {
                Some('0') => out.push('~'),
                Some('1') => out.push('/'),
                Some(other) => {
                    return Err(format!("invalid escape ~{other} in json pointer token"));
                }
                None => return Err("trailing ~ in json pointer token".to_string()),
            }
        } else {
            out.push(ch);
        }
    }

    Ok(out)
}

fn descend_or_create<'a>(value: &'a mut Value, token: &str) -> Result<&'a mut Value, String> {
    match value {
        Value::Object(map) => Ok(map
            .entry(token.to_string())
            .or_insert_with(|| Value::Object(serde_json::Map::new()))),
        Value::Array(items) => {
            let index = parse_index(token, items.len(), token)?;
            items
                .get_mut(index)
                .ok_or_else(|| format!("array index out of bounds at token {token}"))
        }
        _ => Err(format!(
            "cannot descend into non-container value at token {token}"
        )),
    }
}

fn descend_existing<'a>(value: &'a mut Value, token: &str) -> Option<&'a mut Value> {
    match value {
        Value::Object(map) => map.get_mut(token),
        Value::Array(items) => token
            .parse::<usize>()
            .ok()
            .and_then(|index| items.get_mut(index)),
        _ => None,
    }
}

fn parse_index(token: &str, max_len: usize, path: &str) -> Result<usize, String> {
    let index = token
        .parse::<usize>()
        .map_err(|_| format!("invalid array index '{token}' at path {path}"))?;

    if index > max_len {
        Err(format!(
            "array index out of bounds '{token}' at path {path}"
        ))
    } else {
        Ok(index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_rev_accepts_first_and_next_revision() {
        let mut state = UiModelState::default();
        assert!(validate_render_rev(&state, 1).is_ok());
        mark_applied_rev(&mut state, 1);
        assert!(validate_render_rev(&state, 2).is_ok());
    }

    #[test]
    fn render_rev_rejects_stale_or_skipped_revisions() {
        let mut state = UiModelState::default();
        mark_applied_rev(&mut state, 5);
        assert!(validate_render_rev(&state, 5).is_err());
        assert!(validate_render_rev(&state, 4).is_err());
        assert!(validate_render_rev(&state, 7).is_err());
    }

    #[test]
    fn patch_rev_requires_next_monotonic_revision() {
        let mut state = UiModelState::default();
        assert!(validate_patch_rev(&state, 1).is_err());
        mark_applied_rev(&mut state, 3);
        assert!(validate_patch_rev(&state, 4).is_ok());
        assert!(validate_patch_rev(&state, 5).is_err());
    }

    #[test]
    fn ack_tracking_uses_monotonic_high_watermark() {
        let mut state = UiModelState::default();
        mark_applied_ack(&mut state, None);
        assert_eq!(state.last_ack, None);

        mark_applied_ack(&mut state, Some(5));
        assert_eq!(state.last_ack, Some(5));

        mark_applied_ack(&mut state, Some(3));
        assert_eq!(state.last_ack, Some(5));

        mark_applied_ack(&mut state, Some(8));
        assert_eq!(state.last_ack, Some(8));
    }
}
