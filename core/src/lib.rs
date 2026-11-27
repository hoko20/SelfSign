//! selfsign-core
//!
//! On-device self-signing engine for iOS 26+.
//!
//! Flow implemented here:
//!   Apple ID (+2FA) -> anisette v3 -> Xcode developer session -> free
//!   development certificate + provisioning profile -> zsign re-sign ->
//!   install through the RemotePairing/TLS-PSK/CDTunnel/RSD stack.
//!
//! The public surface is a C ABI (`extern "C"`) consumed by the Swift app.
//! Every long-running call is **blocking**; Swift must call them off the main
//! actor. Progress / prompts are delivered through function-pointer callbacks.

pub mod error;
pub mod storage;
pub mod session;
pub mod tunnel;
pub mod ffi;

use std::sync::Once;

static INIT: Once = Once::new();

/// Idempotent process-wide initialization. Must be called before any other
/// entry point (installs isideload's error formatter + rustls crypto provider).
#[unsafe(no_mangle)]
pub extern "C" fn ss_init() -> i32 {
    let mut result = 0i32;
    INIT.call_once(|| {
        // rustls needs an explicit crypto provider when multiple backends are
        // linked. `ring` is selected by our feature set.
        if rustls::crypto::ring::default_provider()
            .install_default()
            .is_err()
        {
            // A provider was already installed by the process; that is fine.
        }
        if isideload::init().is_err() {
            result = -1;
        }
        let _ = tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
            )
            .try_init();
    });
    result
}

/// Returns a human-readable description for the last error on this thread.
/// The buffer is overwritten on every call; `len` is the buffer capacity.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ss_last_error(buf: *mut i8, len: i32) -> i32 {
    if buf.is_null() || len <= 0 {
        return 0;
    }
    let msg = error::take_last_error();
    let bytes = msg.as_bytes();
    let copy_len = bytes.len().min((len - 1) as usize);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, copy_len);
        *buf.add(copy_len) = 0;
    }
    copy_len as i32
}
