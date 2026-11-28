//! C ABI exposed to Swift.
//!
//! Naming convention: `ss_*`. All functions that take a `*mut Session` are
//! blocking and must be called from a background queue by Swift.

use std::ffi::{CStr, c_char, c_int, c_void};
use std::path::PathBuf;

use serde::Deserialize;

use crate::error::{set_last_error, take_last_error};
use crate::session::{NotifyCallback, Session, SessionConfig};
use crate::storage::StorageRoot;

#[derive(Debug, Deserialize)]
struct ConfigJson {
    apple_id: String,
    app_password: String,
    #[serde(default)]
    anisette_url: Option<String>,
    storage_root: String,
    pairing_dir: String,
    #[serde(default = "default_host")]
    tunnel_host: String,
    #[serde(default = "default_machine")]
    machine_name: String,
    #[serde(default)]
    team_id: Option<String>,
}

fn default_host() -> String {
    "10.7.0.1".to_string()
}
fn default_machine() -> String {
    "SelfSign".to_string()
}

unsafe fn str_from(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("null string pointer".to_string());
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(|s| s.to_string())
        .map_err(|e| format!("invalid utf-8: {e}"))
}

/// Create a session from a JSON config. Returns NULL on error; call
/// `ss_last_error()` for details.
///
/// ```json
/// {
///   "apple_id": "you@icloud.com",
///   "app_password": "xxxx-xxxx-xxxx-xxxx",
///   "anisette_url": "https://anisette.example.com/v3",
///   "storage_root": "/var/mobile/.../Application Support/selfsign",
///   "pairing_dir":  "/var/mobile/.../Application Support/selfsign/pairings",
///   "tunnel_host":  "10.7.0.1",
///   "machine_name": "SelfSign",
///   "team_id": null
/// }
/// ```
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_session_new(config_json: *const c_char) -> *mut Session {
    match str_from(config_json).and_then(|raw| {
        let cfg: ConfigJson =
            serde_json::from_str(&raw).map_err(|e| format!("config json: {e}"))?;
        Ok(SessionConfig {
            apple_id: cfg.apple_id,
            app_password: cfg.app_password,
            anisette_url: cfg.anisette_url,
            storage_root: StorageRoot::new(cfg.storage_root),
            pairing_dir: PathBuf::from(cfg.pairing_dir),
            tunnel_host: cfg.tunnel_host,
            machine_name: cfg.machine_name,
            team_id: cfg.team_id,
        })
    }) {
        Ok(cfg) => match Session::new(cfg) {
            Ok(session) => Box::into_raw(Box::new(session)),
            Err(e) => {
                set_last_error(e);
                std::ptr::null_mut()
            }
        },
        Err(e) => {
            set_last_error(e);
            std::ptr::null_mut()
        }
    }
}

/// Register the callback Swift uses for prompts/progress/log lines.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_session_set_callback(
    session: *mut Session,
    cb: NotifyCallback,
    ctx: *mut c_void,
) -> c_int {
    if session.is_null() {
        return -1;
    }
    (*session).set_sink(cb, ctx);
    0
}

/// Sign in with the Apple ID. Blocking; prompts 2FA through the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_sign_in(session: *mut Session) -> c_int {
    if session.is_null() {
        return -1;
    }
    match (*session).sign_in() {
        Ok(_) => 0,
        Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Sign + install an IPA. Blocking; emits progress through the callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_sign_install(session: *mut Session, ipa_path: *const c_char) -> c_int {
    if session.is_null() {
        return -1;
    }
    let path = match str_from(ipa_path) {
        Ok(p) => p,
        Err(e) => {
            set_last_error(e);
            return -1;
        }
    };
    match (*session).sign_and_install(&path) {
        Ok(_) => 0,
        Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Answer a pending 2FA / certificate prompt.
/// Accepts `code:123456`, `sms:1`, `devices`, `resend`, `abort`,
/// `cert:<serial>,<serial>`, `none`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_respond(session: *mut Session, answer: *const c_char) -> c_int {
    if session.is_null() {
        return -1;
    }
    match str_from(answer) {
        Ok(a) => {
            (*session).respond(&a);
            0
        }
        Err(e) => {
            set_last_error(e);
            -1
        }
    }
}

/// Cancel the running operation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_cancel(session: *mut Session) -> c_int {
    if session.is_null() {
        return -1;
    }
    (*session).cancel();
    0
}

/// Free a session. Must not be called while another thread uses it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_session_free(session: *mut Session) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

/// iOS 27+ on-device pairing. Advertises as a pairable host, produces a 6-digit
/// PIN via `pin_cb`, and writes the resulting pairing file into `pairing_dir`.
///
/// BLOCKING — call from a background queue. Returns 0 on success.
/// `pin_cb(pin_ptr, pin_len, ctx)` — the PIN is NOT null-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_pair_start(
    pairing_dir: *const c_char,
    display_name: *const c_char,
    machine_model: *const c_char,
    pin_cb: crate::pair::PinCallback,
    ctx: *mut c_void,
) -> c_int {
    let dir = match str_from(pairing_dir) {
        Ok(d) => d,
        Err(e) => {
            set_last_error(e);
            return -1;
        }
    };
    let name = str_from(display_name).unwrap_or_else(|_| "SelfSign".to_string());
    let model = str_from(machine_model).unwrap_or_else(|_| "Mac17,7".to_string());
    match crate::pair::run_on_device_pairing(
        std::path::Path::new(&dir),
        &name,
        &model,
        pin_cb,
        ctx,
    ) {
        Ok(_) => 0,
        Err(e) => {
            set_last_error(e.to_string());
            -1
        }
    }
}

/// Return the last error as a newly allocated UTF-8 string. Caller must
/// release it with `ss_string_free()`.
#[unsafe(no_mangle)]
pub extern "C" fn ss_take_error() -> *mut c_char {
    let msg = take_last_error();
    let c = std::ffi::CString::new(msg).unwrap_or_else(|_| std::ffi::CString::new("error").unwrap());
    c.into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(std::ffi::CString::from_raw(s));
    }
}
