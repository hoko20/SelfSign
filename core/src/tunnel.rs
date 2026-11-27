//! Device link for on-device installation.
//!
//! The app cannot use usbmuxd on itself. LocalDevVPN (a NEPacketTunnelProvider
//! from the App Store) reflects `10.7.1.1 -> 10.7.0.1` packets into the phone's
//! own RemotePairing service. We then:
//!
//!   1. connect to `10.7.0.1:49152`
//!   2. pair-verify with the saved RP pairing file
//!   3. `create_tcp_listener` -> connect to the returned port
//!   4. TLS 1.2 PSK tunnel + CDTunnel handshake -> IPv6 addresses + RSD port
//!   5. jktcp user-space TCP stack over the raw IPv6 tunnel
//!   6. RSD handshake -> AFC upload + installation_proxy install

use std::path::{Path, PathBuf};
use std::sync::Arc;

use idevice::{
    ReadWrite, RsdService,
    afc::{AfcClient, opcode::AfcFopenMode},
    installation_proxy::InstallationProxyClient,
    remote_pairing::{
        RemotePairingClient, connect_tls_psk_tunnel_native,
        rp_pairing_file::RpPairingFile,
    },
    services::rsd::RsdHandshake,
    tcp,
};
use plist_macro::plist;

use crate::error::set_last_error;
use crate::session::PromptBus;

const RPAIR_PORT: u16 = 49152;

/// Owns the established tunnel + jktcp adapter for one install.
pub struct DeviceLink {
    adapter: tcp::handle::AdapterHandle,
    handshake: RsdHandshake,
    udid: String,
}

impl DeviceLink {
    /// Establish the full tunnel to the local device.
    pub async fn connect(
        tunnel_host: &str,
        pairing_dir: &Path,
        machine_name: &str,
        _bus: Arc<PromptBus>,
    ) -> Result<Self, String> {
        let host = if tunnel_host.is_empty() {
            "10.7.0.1".to_string()
        } else {
            tunnel_host.to_string()
        };

        let pairing_path = find_pairing_file(pairing_dir)?;
        let pairing_bytes = std::fs::read(&pairing_path)
            .map_err(|e| format!("read pairing file: {e}"))?;
        let mut pairing = RpPairingFile::from_bytes(&pairing_bytes)
            .map_err(|e| format!("parse pairing file: {e}"))?;

        // 1+2. RemotePairing pair-verify over the reflected localhost socket.
        let stream = tokio::net::TcpStream::connect((host.as_str(), RPAIR_PORT))
            .await
            .map_err(|e| {
                let msg = format!("connect {host}:{RPAIR_PORT} (is LocalDevVPN on?): {e}");
                set_last_error(&msg);
                msg
            })?;
        let mut rpc = RemotePairingClient::new(stream, machine_name);
        let _ = rpc.attempt_pair_verify().await;
        rpc.validate_pairing(&mut pairing)
            .await
            .map_err(|e| format!("pair-verify failed (re-pair in Settings): {e}"))?;

        // 3. Ask remotepairingd for a tunnel port, then connect to it.
        let port = rpc
            .create_tcp_listener()
            .await
            .map_err(|e| format!("create_tcp_listener: {e}"))?;
        let tunnel_stream = tokio::net::TcpStream::connect((host.as_str(), port))
            .await
            .map_err(|e| format!("connect tunnel port {port}: {e}"))?;

        // 4. TLS-PSK + CDTunnel handshake.
        let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
            .await
            .map_err(|e| format!("TLS-PSK/CDTunnel handshake: {e}"))?;
        let client_ip: std::net::IpAddr = tunnel
            .info
            .client_address
            .parse()
            .map_err(|e| format!("client address: {e}"))?;
        let server_ip: std::net::IpAddr = tunnel
            .info
            .server_address
            .parse()
            .map_err(|e| format!("server address: {e}"))?;
        let rsd_port = tunnel.info.server_rsd_port;

        // 5. User-space TCP stack over the raw IPv6 tunnel.
        let raw = tunnel.into_inner();
        let adapter = tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
        let mut handle = adapter.to_async_handle();

        // 6. RSD handshake through the tunnel.
        let rsd_stream = handle
            .connect(rsd_port)
            .await
            .map_err(|e| format!("connect RSD port {rsd_port}: {e}"))?;
        let mut handshake = RsdHandshake::new(rsd_stream)
            .await
            .map_err(|e| format!("RSD handshake: {e}"))?;

        let udid = handshake
            .properties
            .get("UniqueDeviceID")
            .and_then(|v| v.as_string())
            .map(|s| s.to_string())
            .unwrap_or_else(|| machine_name.to_string());

        Ok(Self {
            adapter: handle,
            handshake,
            udid,
        })
    }

    pub fn udid(&self) -> Option<&str> {
        Some(&self.udid)
    }

    /// Upload the signed .app via AFC and install with installation_proxy over RSD.
    pub async fn install<F>(&mut self, app_path: &Path, progress: F) -> Result<(), String>
    where
        F: Fn(u64) + Send + Sync,
    {
        let mut afc = AfcClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(|e| format!("AFC connect_rsd: {e}"))?;
        let dir = format!(
            "PublicStaging/{}",
            app_path
                .file_name()
                .ok_or("bad app path")?
                .to_string_lossy()
        );
        afc.mk_dir(&dir)
            .await
            .map_err(|e| format!("AFC mk_dir: {e}"))?;
        upload_dir(&mut afc, app_path, &dir, &progress).await?;

        let mut inst = InstallationProxyClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(|e| format!("installation_proxy connect_rsd: {e}"))?;
        let opts = plist!(dict { "PackageType": "Developer" });
        inst.install_with_callback(
            dir,
            Some(plist::Value::Dictionary(opts)),
            async |(pct, _)| progress(70 + ((pct as u64) * 30) / 100),
            (),
        )
        .await
        .map_err(|e| format!("install_with_callback: {e}"))?;
        Ok(())
    }
}

/// Recursively upload a signed .app bundle through AFC (1 MiB chunks).
fn upload_dir<'a, F>(
    afc: &'a mut AfcClient,
    path: &'a Path,
    afc_dir: &'a str,
    progress: &'a F,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), String>> + Send + 'a>>
where
    F: Fn(u64) + Send + Sync,
{
    Box::pin(async move {
        let entries = std::fs::read_dir(path).map_err(|e| format!("read_dir: {e}"))?;
        for entry in entries {
            let entry = entry.map_err(|e| format!("dir entry: {e}"))?;
            let child = entry.path();
            let name = child.file_name().unwrap_or_default().to_string_lossy();
            let target = format!("{afc_dir}/{name}");
            if child.is_dir() {
                afc.mk_dir(&target)
                    .await
                    .map_err(|e| format!("AFC mk_dir {target}: {e}"))?;
                upload_dir(afc, &child, &target, progress).await?;
            } else {
                let mut file = afc
                    .open(target, AfcFopenMode::WrOnly)
                    .await
                    .map_err(|e| format!("AFC open: {e}"))?;
                let bytes = std::fs::read(&child).map_err(|e| format!("read file: {e}"))?;
                for chunk in bytes.chunks(1024 * 1024) {
                    file.write_entire(chunk)
                        .await
                        .map_err(|e| format!("AFC write: {e}"))?;
                }
                file.close().await.map_err(|e| format!("AFC close: {e}"))?;
            }
        }
        Ok(())
    })
}

fn find_pairing_file(dir: &Path) -> Result<PathBuf, String> {
    let direct = dir.join("rp_pairing_file.plist");
    if direct.exists() {
        return Ok(direct);
    }
    let entries = std::fs::read_dir(dir).map_err(|e| format!("pairing dir: {e}"))?;
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_dir() {
            let nested = p.join("rp_pairing_file.plist");
            if nested.exists() {
                return Ok(nested);
            }
        }
    }
    Err("no rp_pairing_file.plist found; pair the device first".to_string())
}
