//! iOS 27+ device-initiated on-device pairing.
//!
//! Starting with iOS 27 the device can initiate pairing to a *pairable host*.
//! SelfSign acts as that host: it advertises `_remotepairing-pairable-host._tcp`
//! over mDNS, listens on a local TCP port, and drives the SRP pair-setup as the
//! responder. A 6-digit PIN is produced and shown in Swift; the user types it
//! into Settings → Privacy & Security → Developer Mode → Pair This iPhone.
//! On success a `RpPairingFile` is written into the app's pairing directory —
//! no computer, no external pairing service involved.
//!
//! This module is compiled only for `install` builds (default).

use std::net::Ipv4Addr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use idevice::IdeviceError;
use idevice::remote_pairing::{
    PAIRABLE_HOST_SERVICE_TYPE, PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
};
use mdns_sd::{ServiceDaemon, ServiceInfo};
use tokio::net::TcpListener;

/// Handle returned to Swift. `stop()` shuts the mDNS daemon and cancels the
/// accept loop. Dropping it also stops the daemon.
pub struct OnDevicePairer {
    stop: Arc<AtomicBool>,
    mdns: Option<Arc<ServiceDaemon>>,
}

impl OnDevicePairer {
    /// True while the pairing session is still accepting a device connection.
    pub fn is_running(&self) -> bool {
        !self.stop.load(Ordering::Relaxed)
    }

    /// Cancel the session. Safe to call multiple times.
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(mdns) = self.mdns.take() {
            let _ = mdns.shutdown();
        }
    }
}

impl Drop for OnDevicePairer {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Callback the Rust side invokes with the 6-digit PIN to display.
pub type PinCallback = unsafe extern "C" fn(*const std::ffi::c_char, i32, *mut std::ffi::c_void);

/// Start advertising as a pairable host and wait for the device to connect.
///
/// This is a **blocking** call: Swift must invoke it on a background queue.
/// `pin_cb` is called once with the setup code; the device then completes the
/// handshake. `out_dir` is where the resulting `pairingFile.plist` is written.
pub fn run_on_device_pairing(
    out_dir: &Path,
    display_name: &str,
    machine_model: &str,
    pin_cb: PinCallback,
    pin_ctx: *mut std::ffi::c_void,
) -> Result<PathBuf, IdeviceError> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| IdeviceError::Other(format!("runtime: {e}")))?;

    rt.block_on(async move {
        async_pair(out_dir, display_name, machine_model, pin_cb, pin_ctx).await
    })
}

async fn async_pair(
    out_dir: &Path,
    display_name: &str,
    machine_model: &str,
    pin_cb: PinCallback,
    pin_ctx: *mut std::ffi::c_void,
) -> Result<PathBuf, IdeviceError> {
    // Bind first so we advertise the real, OS-assigned port.
    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0))
        .await
        .map_err(|e| IdeviceError::Other(format!("bind: {e}")))?;
    let port = listener
        .local_addr()
        .map_err(|e| IdeviceError::Other(format!("local_addr: {e}")))?
        .port();

    // Persistent identity: generate once, reuse on subsequent runs so an
    // already-paired device keeps recognizing this host.
    let mut pairing_file = RpPairingFile::generate(display_name);
    let mut host_info = PairableHostInfo::generate(display_name, machine_model);
    let service_identifier = pairing_file.identifier().to_string();

    let mdns = ServiceDaemon::new()
        .map_err(|e| IdeviceError::Other(format!("mdns daemon: {e}")))?;
    mdns.set_service_name_len_max(30)
        .map_err(|e| IdeviceError::Other(format!("mdns name len: {e}")))?;
    let hostname = format!("selfsign-{}.local.", &service_identifier[..8]);
    let txt = host_info.mdns_txt_records(&service_identifier);
    let properties: Vec<(&str, &str)> = txt.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let service_info = ServiceInfo::new(
        PAIRABLE_HOST_SERVICE_TYPE,
        &service_identifier,
        &hostname,
        "",
        port,
        &properties[..],
    )
    .and_then(|s| s.enable_addr_auto())
    .map_err(|e| IdeviceError::Other(format!("service info: {e}")))?;
    mdns.register(service_info)
        .map_err(|e| IdeviceError::Other(format!("mdns register: {e}")))?;

    let (stream, peer) = listener
        .accept()
        .await
        .map_err(|e| IdeviceError::Other(format!("accept: {e}")))?;
    tracing::info!(target: "selfsign", "pairable host: device connected from {peer}");

    // Surface the PIN through FFI, then let Swift display it while the device
    // completes pair-setup. The callback is synchronous; Swift may copy it.
    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);
    let pin_ctx_val = pin_ctx as usize;
    let peer = host
        .accept(&mut pairing_file, |pin| async move {
            let bytes = pin.as_bytes();
            unsafe {
                pin_cb(
                    bytes.as_ptr() as *const std::ffi::c_char,
                    bytes.len() as i32,
                    pin_ctx_val as *mut std::ffi::c_void,
                );
            }
        })
        .await?;

    let _ = mdns.shutdown();

    std::fs::create_dir_all(out_dir)
        .map_err(|e| IdeviceError::Other(format!("create pairing dir: {e}")))?;
    let out_path = out_dir.join("pairingFile.plist");
    pairing_file.write_to_file(&out_path).await?;
    tracing::info!(target: "selfsign", "paired with {} ({}) -> {}", peer.name, peer.model, out_path.display());
    Ok(out_path)
}
