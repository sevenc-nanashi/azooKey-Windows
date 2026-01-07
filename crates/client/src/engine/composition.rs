use std::cmp::{max, min};
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

// Cooldown for IPC reconnection attempts (10 seconds)
static LAST_IPC_FAIL_TIME: AtomicU64 = AtomicU64::new(0);
const IPC_RECONNECT_COOLDOWN_SECS: u64 = 10;

fn should_try_ipc_reconnect() -> bool {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let last_fail = LAST_IPC_FAIL_TIME.load(Ordering::Relaxed);
    now.saturating_sub(last_fail) >= IPC_RECONNECT_COOLDOWN_SECS
}

fn mark_ipc_reconnect_failed() {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    LAST_IPC_FAIL_TIME.store(now, Ordering::Relaxed);
}

// Debug helper - write to file since println doesn't work in DLLs
fn debug_log(msg: &str) {
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("G:/Projects/azooKey-Windows/logs/debug.log")
    {
        let _ = writeln!(file, "[{}] {}", chrono::Local::now().format("%H:%M:%S%.3f"), msg);
    }
}

use crate::{
    engine::user_action::UserAction,
    extension::VKeyExt as _,
    tsf::factory::{TextServiceFactory, TextServiceFactory_Impl},
};

use super::{
    client_action::{ClientAction, SetSelectionType, SetTextType},
    full_width::{to_fullwidth, to_halfwidth},
    input_mode::InputMode,
    ipc_service::{Candidates, IPCService},
    state::IMEState,
    text_util::{to_half_katakana, to_katakana},
    user_action::{Function, Navigation},
};
use windows::Win32::{
    Foundation::WPARAM,
    UI::{
        Input::KeyboardAndMouse::{VK_CONTROL, VK_LCONTROL, VK_RCONTROL},
        TextServices::{ITfComposition, ITfCompositionSink_Impl, ITfContext},
    },
};

use anyhow::{Context, Result};

#[derive(Default, Clone, PartialEq, Debug)]
pub enum CompositionState {
    #[default]
    None,
    Composing,
    Previewing,
    Selecting,
}

#[derive(Default, Clone, Debug)]
pub struct Composition {
    pub preview: String, // text to be previewed
    pub suffix: String,  // text to be appended after preview
    pub raw_input: String,
    pub raw_hiragana: String,

    pub corresponding_count: i32, // corresponding count of the preview

    pub selection_index: i32,
    pub candidates: Candidates,

    pub state: CompositionState,
    pub tip_composition: Option<ITfComposition>,
}

impl ITfCompositionSink_Impl for TextServiceFactory_Impl {
    #[macros::anyhow]
    fn OnCompositionTerminated(
        &self,
        _ecwrite: u32,
        _pcomposition: Option<&ITfComposition>,
    ) -> Result<()> {
        // if user clicked outside the composition, the composition will be terminated
        tracing::debug!("OnCompositionTerminated");

        let actions = vec![ClientAction::EndComposition];
        self.handle_action(&actions, CompositionState::None)?;

        Ok(())
    }
}

impl TextServiceFactory {
    #[tracing::instrument]
    pub fn process_key(
        &self,
        context: Option<&ITfContext>,
        wparam: WPARAM,
    ) -> Result<Option<(Vec<ClientAction>, CompositionState)>> {
        if context.is_none() {
            return Ok(None);
        };

        // IME ON/OFF switching via special key codes from AutoHotkey
        // 0x97 = IME OFF (English), 0x98 = IME ON (Japanese)
        // These are unassigned VK codes that won't conflict with system keys
        // IMPORTANT: Check these BEFORE VK_CONTROL check to avoid timing issues
        // when AutoHotkey sends these keys right after Ctrl release
        if wparam.0 == 0x97 {
            // IME OFF (English)
            return Ok(Some((
                vec![ClientAction::SetIMEMode(InputMode::Latin)],
                CompositionState::None,
            )));
        }
        if wparam.0 == 0x98 {
            // IME ON (Japanese)
            return Ok(Some((
                vec![ClientAction::SetIMEMode(InputMode::Kana)],
                CompositionState::None,
            )));
        }

        // check shortcut keys
        if VK_CONTROL.is_pressed() {
            return Ok(None);
        }

        #[allow(clippy::let_and_return)]
        let (composition, mode) = {
            let text_service = self.borrow()?;
            let composition = text_service.borrow_composition()?.clone();
            let mode = IMEState::get()?.input_mode.clone();
            (composition, mode)
        };

        // Debug: log key event info
        debug_log(&format!("process_key: wparam={}, mode={:?}, state={:?}", wparam.0, mode, composition.state));

        let action = UserAction::try_from(wparam.0)?;
        debug_log(&format!("action: {:?}", action));

        let (transition, actions) = match composition.state {
            CompositionState::None => match action {
                UserAction::Input(char) if mode == InputMode::Kana => (
                    CompositionState::Composing,
                    vec![
                        ClientAction::StartComposition,
                        ClientAction::AppendText(char.to_string()),
                    ],
                ),
                UserAction::Number(number) if mode == InputMode::Kana => (
                    CompositionState::Composing,
                    vec![
                        ClientAction::StartComposition,
                        ClientAction::AppendText(number.to_string()),
                    ],
                ),
                UserAction::ToggleInputMode => (
                    CompositionState::None,
                    vec![match mode {
                        InputMode::Kana => ClientAction::SetIMEMode(InputMode::Latin),
                        InputMode::Latin => ClientAction::SetIMEMode(InputMode::Kana),
                    }],
                ),
                _ => {
                    return Ok(None);
                }
            },
            CompositionState::Composing => match action {
                UserAction::Input(char) => (
                    CompositionState::Composing,
                    vec![ClientAction::AppendText(char.to_string())],
                ),
                UserAction::Number(number) => (
                    CompositionState::Composing,
                    vec![ClientAction::AppendText(number.to_string())],
                ),
                UserAction::Backspace => {
                    if composition.preview.chars().count() == 1 {
                        (
                            CompositionState::None,
                            vec![ClientAction::RemoveText, ClientAction::EndComposition],
                        )
                    } else {
                        (CompositionState::Composing, vec![ClientAction::RemoveText])
                    }
                }
                UserAction::Enter => {
                    if composition.suffix.is_empty() {
                        (CompositionState::None, vec![ClientAction::EndComposition])
                    } else {
                        (
                            CompositionState::Composing,
                            vec![ClientAction::ShrinkText("".to_string())],
                        )
                    }
                }
                UserAction::Escape => (
                    CompositionState::None,
                    vec![ClientAction::RemoveText, ClientAction::EndComposition],
                ),
                UserAction::Navigation(direction) => match direction {
                    Navigation::Right => (
                        CompositionState::Composing,
                        vec![ClientAction::MoveCursor(1)],
                    ),
                    Navigation::Left => (
                        CompositionState::Composing,
                        vec![ClientAction::MoveCursor(-1)],
                    ),
                    Navigation::Up => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetSelection(SetSelectionType::Up)],
                    ),
                    Navigation::Down => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetSelection(SetSelectionType::Down)],
                    ),
                },
                UserAction::ToggleInputMode => (
                    CompositionState::None,
                    vec![
                        ClientAction::EndComposition,
                        ClientAction::SetIMEMode(InputMode::Latin),
                    ],
                ),
                UserAction::Space | UserAction::Tab => (
                    CompositionState::Previewing,
                    vec![ClientAction::SetSelection(SetSelectionType::Down)],
                ),
                UserAction::Function(key) => match key {
                    Function::Six => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::Hiragana)],
                    ),
                    Function::Seven => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::Katakana)],
                    ),
                    Function::Eight => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::HalfKatakana)],
                    ),
                    Function::Nine => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::FullLatin)],
                    ),
                    Function::Ten => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::HalfLatin)],
                    ),
                },
                _ => {
                    return Ok(None);
                }
            },
            CompositionState::Previewing => match action {
                UserAction::Input(char) => (
                    CompositionState::Composing,
                    vec![ClientAction::ShrinkText(char.to_string())],
                ),
                UserAction::Number(number) => (
                    CompositionState::Composing,
                    vec![ClientAction::ShrinkText(number.to_string())],
                ),
                UserAction::Backspace => {
                    if composition.preview.chars().count() == 1 {
                        (
                            CompositionState::None,
                            vec![ClientAction::RemoveText, ClientAction::EndComposition],
                        )
                    } else {
                        (CompositionState::Composing, vec![ClientAction::RemoveText])
                    }
                }
                UserAction::Enter => {
                    if composition.suffix.is_empty() {
                        (CompositionState::None, vec![ClientAction::EndComposition])
                    } else {
                        (
                            CompositionState::Composing,
                            vec![ClientAction::ShrinkText("".to_string())],
                        )
                    }
                }
                UserAction::Escape => (
                    CompositionState::None,
                    vec![ClientAction::RemoveText, ClientAction::EndComposition],
                ),
                UserAction::Navigation(direction) => match direction {
                    Navigation::Right => (
                        CompositionState::Composing,
                        vec![ClientAction::MoveCursor(1)],
                    ),
                    Navigation::Left => (
                        CompositionState::Composing,
                        vec![ClientAction::MoveCursor(-1)],
                    ),
                    Navigation::Up => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetSelection(SetSelectionType::Up)],
                    ),
                    Navigation::Down => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetSelection(SetSelectionType::Down)],
                    ),
                },
                UserAction::ToggleInputMode => (
                    CompositionState::None,
                    vec![
                        ClientAction::EndComposition,
                        ClientAction::SetIMEMode(InputMode::Latin),
                    ],
                ),
                UserAction::Space | UserAction::Tab => (
                    CompositionState::Previewing,
                    vec![ClientAction::SetSelection(SetSelectionType::Down)],
                ),
                UserAction::Function(key) => match key {
                    Function::Six => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::Hiragana)],
                    ),
                    Function::Seven => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::Katakana)],
                    ),
                    Function::Eight => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::HalfKatakana)],
                    ),
                    Function::Nine => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::FullLatin)],
                    ),
                    Function::Ten => (
                        CompositionState::Previewing,
                        vec![ClientAction::SetTextWithType(SetTextType::HalfLatin)],
                    ),
                },
                _ => {
                    return Ok(None);
                }
            },
            _ => {
                return Ok(None);
            }
        };

        Ok(Some((actions, transition)))
    }

    #[tracing::instrument]
    pub fn handle_key(&self, context: Option<&ITfContext>, wparam: WPARAM) -> Result<bool> {
        if let Some(context) = context {
            self.borrow_mut()?.context = Some(context.clone());
        } else {
            return Ok(false);
        };

        if let Some((actions, transition)) = self.process_key(context, wparam)? {
            self.handle_action(&actions, transition)?;
        } else {
            return Ok(false);
        }

        Ok(true)
    }

    #[tracing::instrument]
    pub fn handle_action(
        &self,
        actions: &[ClientAction],
        transition: CompositionState,
    ) -> Result<()> {
        #[allow(clippy::let_and_return)]
        let (composition, mode) = {
            let text_service = self.borrow()?;
            let composition = text_service.borrow_composition()?.clone();
            let mode = IMEState::get()?.input_mode.clone();
            (composition, mode)
        };

        let mut preview = composition.preview.clone();
        let mut suffix = composition.suffix.clone();
        let mut raw_input = composition.raw_input.clone();
        let mut raw_hiragana = composition.raw_hiragana.clone();
        let mut corresponding_count = composition.corresponding_count.clone();
        let mut candidates = composition.candidates.clone();
        let mut selection_index = composition.selection_index;
        // IPC service is optional - some actions (like SetIMEMode) don't need it
        let mut ipc_service = IMEState::get()?.ipc_service.clone();
        let mut transition = transition;

        // Helper macro to get IPC service, with lazy reconnection if needed
        // Returns Result<&mut IPCService, anyhow::Error>
        // Uses cooldown to avoid blocking UI with repeated failed connection attempts
        macro_rules! require_ipc {
            () => {{
                if ipc_service.is_none() && should_try_ipc_reconnect() {
                    // Try lazy reconnection (only if cooldown has passed)
                    tracing::debug!("IPC service is None, attempting lazy reconnection...");
                    debug_log("Attempting lazy IPC reconnection...");
                    match IPCService::new() {
                        Ok(new_ipc) => {
                            tracing::debug!("Lazy IPC reconnection successful");
                            debug_log("Lazy IPC reconnection successful");
                            ipc_service = Some(new_ipc);
                            // Also update the global state
                            if let Ok(mut state) = IMEState::get() {
                                state.ipc_service = ipc_service.clone();
                            }
                        }
                        Err(e) => {
                            tracing::warn!("Lazy IPC reconnection failed: {:?}", e);
                            debug_log(&format!("Lazy IPC reconnection failed: {:?}", e));
                            mark_ipc_reconnect_failed();
                        }
                    }
                }
                ipc_service
                    .as_mut()
                    .context("IPC service not available")
            }};
        }

        // Skip update_context to reduce RequestEditSession calls
        // Qt apps crash when multiple RequestEditSession calls happen in rapid succession
        // update_context is used for surrounding text context (non-essential)
        // TODO: Re-enable for non-Qt apps if needed
        // self.update_context(&preview)?;

        debug_log(&format!("handle_action: actions={:?}, ipc_available={}", actions, ipc_service.is_some()));

        // Helper macro to try IPC but continue on failure (for optional IPC calls)
        macro_rules! try_ipc {
            ($expr:expr) => {{
                if let Some(ref mut ipc) = ipc_service {
                    let _ = $expr(ipc);
                }
            }};
        }

        for action in actions {
            match action {
                ClientAction::StartComposition => {
                    self.start_composition()?;
                    self.update_pos()?;
                    // Show window is optional - works without server
                    try_ipc!(|ipc: &mut IPCService| ipc.show_window());
                }
                ClientAction::EndComposition => {
                    self.end_composition()?;
                    selection_index = 0;
                    corresponding_count = 0;
                    preview.clear();
                    suffix.clear();
                    raw_input.clear();
                    raw_hiragana.clear();
                    // UI calls are optional - works without server
                    try_ipc!(|ipc: &mut IPCService| ipc.hide_window());
                    try_ipc!(|ipc: &mut IPCService| ipc.set_candidates(vec![]));
                    try_ipc!(|ipc: &mut IPCService| ipc.clear_text());
                }
                ClientAction::AppendText(text) => {
                    raw_input.push_str(&text);

                    let fullwidth_text = match mode {
                        InputMode::Kana => to_fullwidth(text, false),
                        InputMode::Latin => text.to_string(),
                    };

                    // Try to get candidates from server, fall back to showing hiragana
                    if let Ok(ipc) = require_ipc!() {
                        candidates = ipc.append_text(fullwidth_text.clone())?;
                        let conv_text = candidates.texts[selection_index as usize].clone();
                        let sub_text = candidates.sub_texts[selection_index as usize].clone();
                        let hiragana = candidates.hiragana.clone();

                        corresponding_count = candidates.corresponding_count[selection_index as usize];

                        preview = conv_text.clone();
                        suffix = sub_text.clone();
                        raw_hiragana = hiragana.clone();

                        self.set_text(&conv_text, &sub_text)?;
                        let _ = ipc.set_candidates(candidates.texts.clone());
                        let _ = ipc.set_selection(selection_index as i32);
                    } else {
                        // Offline mode: just show the hiragana without conversion
                        debug_log("Offline mode: showing hiragana without conversion");
                        raw_hiragana.push_str(&fullwidth_text);
                        preview = raw_hiragana.clone();
                        suffix.clear();
                        corresponding_count = raw_hiragana.chars().count() as i32;
                        self.set_text(&preview, "")?;
                    }
                }
                ClientAction::RemoveText => {
                    // Try to use server, fall back to local handling
                    if let Ok(ipc) = require_ipc!() {
                        candidates = ipc.remove_text()?;
                        let empty = "".to_string();
                        let text = candidates
                            .texts
                            .get(selection_index as usize)
                            .cloned()
                            .unwrap_or(empty.clone());
                        let sub_text = candidates
                            .sub_texts
                            .get(selection_index as usize)
                            .cloned()
                            .unwrap_or(empty.clone());
                        let hiragana = candidates.hiragana.clone();
                        corresponding_count = candidates
                            .corresponding_count
                            .get(selection_index as usize)
                            .cloned()
                            .unwrap_or(0);

                        raw_input = raw_input
                            .chars()
                            .take(corresponding_count as usize)
                            .collect();
                        preview = text.clone();
                        suffix = sub_text.clone();
                        raw_hiragana = hiragana.clone();

                        self.set_text(&text, &sub_text)?;
                        let _ = ipc.set_candidates(candidates.texts.clone());
                        let _ = ipc.set_selection(selection_index as i32);
                    } else {
                        // Offline mode: remove last character from hiragana
                        debug_log("Offline mode: removing last character");
                        let mut chars: Vec<char> = raw_hiragana.chars().collect();
                        chars.pop();
                        raw_hiragana = chars.into_iter().collect();
                        raw_input = raw_input.chars().take(raw_input.chars().count().saturating_sub(1)).collect();
                        preview = raw_hiragana.clone();
                        suffix.clear();
                        corresponding_count = raw_hiragana.chars().count() as i32;
                        self.set_text(&preview, "")?;
                    }
                }
                ClientAction::MoveCursor(_offset) => {
                    // TODO: I'll use azookey-kkc's composingText
                    // self.set_cursor(offset)?;
                }
                ClientAction::SetIMEMode(mode) => {
                    // Update the IME state - this is the core functionality
                    let mut ime_state = IMEState::get()?;
                    ime_state.input_mode = mode.clone();

                    // update the language bar icon
                    let _ = self.update_lang_bar();

                    // Reset composition state (local only, no IPC)
                    selection_index = 0;
                    corresponding_count = 0;
                    preview.clear();
                    suffix.clear();
                    raw_input.clear();
                    raw_hiragana.clear();

                    // Note: Skipping IPC calls (set_input_mode, clear_text) as they
                    // use blocking gRPC which can freeze if server is not responding.
                    // The language bar icon update is sufficient for mode indication.
                }
                ClientAction::SetSelection(selection) => {
                    let candidates = {
                        let text_service = self.borrow()?;
                        let composition = text_service.borrow_composition()?.clone();
                        let candidates = composition.candidates.clone();
                        candidates
                    };

                    let texts = candidates.texts.clone();
                    let sub_texts = candidates.sub_texts.clone();

                    selection_index = match selection {
                        SetSelectionType::Up => max(0, selection_index - 1),
                        SetSelectionType::Down => min(texts.len() as i32 - 1, selection_index + 1),
                        SetSelectionType::Number(number) => *number,
                    };

                    // Selection requires server - use ? to propagate error
                    require_ipc!()?.set_selection(selection_index as i32)?;
                    let text = texts[selection_index as usize].clone();
                    let sub_text = sub_texts[selection_index as usize].clone();
                    let hiragana = candidates.hiragana.clone();
                    corresponding_count = candidates.corresponding_count[selection_index as usize];

                    preview = text.clone();
                    suffix = sub_text.clone();
                    raw_hiragana = hiragana.clone();

                    self.set_text(&text, &sub_text)?;
                }
                ClientAction::ShrinkText(text) => {
                    // shrink text - requires server for conversion
                    raw_input.push_str(&text);
                    raw_input = raw_input
                        .chars()
                        .skip(corresponding_count as usize)
                        .collect();

                    require_ipc!()?.shrink_text(corresponding_count.clone())?;
                    let text = match mode {
                        InputMode::Kana => to_fullwidth(text, false),
                        InputMode::Latin => text.to_string(),
                    };
                    candidates = require_ipc!()?.append_text(text)?;
                    selection_index = 0;

                    let text = candidates.texts[selection_index as usize].clone();
                    let sub_text = candidates.sub_texts[selection_index as usize].clone();
                    let hiragana = candidates.hiragana.clone();
                    self.shift_start(&preview, &text)?;

                    corresponding_count = candidates.corresponding_count[selection_index as usize];
                    preview = text.clone();
                    suffix = sub_text.clone();
                    raw_hiragana = hiragana.clone();

                    require_ipc!()?.set_candidates(candidates.texts.clone())?;
                    require_ipc!()?.set_selection(selection_index as i32)?;
                    self.update_pos()?;

                    transition = CompositionState::Composing;
                }
                ClientAction::SetTextWithType(set_type) => {
                    let text = match set_type {
                        SetTextType::Hiragana => raw_hiragana.clone(),
                        SetTextType::Katakana => to_katakana(&raw_hiragana),
                        SetTextType::HalfKatakana => to_half_katakana(&raw_hiragana),
                        SetTextType::FullLatin => to_fullwidth(&raw_input, true),
                        SetTextType::HalfLatin => to_halfwidth(&raw_input),
                    };

                    self.set_text(&text, "")?;
                }
            }
        }

        let text_service = self.borrow()?;
        let mut composition = text_service.borrow_mut_composition()?;

        composition.preview = preview.clone();
        composition.state = transition;
        composition.selection_index = selection_index;
        composition.raw_input = raw_input.clone();
        composition.raw_hiragana = raw_hiragana.clone();
        composition.candidates = candidates;
        composition.suffix = suffix.clone();
        composition.corresponding_count = corresponding_count;

        Ok(())
    }
}
