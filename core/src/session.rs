//! Signing session: owns the Apple ID account, developer session, sideloader
//! and tunnel state for one install / refresh operation.
//!
//! Swift drives this through the C ABI in `ffi.rs`; the async work runs on a
//! tokio current-thread runtime created per session so it composes with the
//! `!Send` parts of the RemotePairing / jktcp stack.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{
        AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse,
    },
    dev::developer_session::DeveloperSession,
    sideload::{
        SideloaderBuilder, TeamSelection,
        builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
    },
    util::callbacks::ExtensionsBehaviorCallbackBox,
};
use rootcause::prelude::*;
use tokio::runtime::Runtime;

use crate::error::set_last_error;
use crate::storage::StorageRoot;
use crate::tunnel::DeviceLink;

/// Callback Swift implements for 2FA prompts and progress updates.
/// `kind`: 0 = 2FA, 1 = progress, 2 = certificate limit, 3 = log.
/// `ctx` is an opaque pointer passed back verbatim.
pub type NotifyCallback =
    extern "C" fn(kind: i32, payload_ptr: *const i8, payload_len: i32, ctx: *mut std::ffi::c_void);

/// Configuration for one session (JSON-supplied from Swift).
#[derive(Debug, Clone)]
pub struct SessionConfig {
    pub apple_id: String,
    pub app_password: String,
    /// anisette-v3 server URL, e.g. `https://anisette.example.com/v3`.
    pub anisette_url: Option<String>,
    /// Where anisette state + certificate keys are cached.
    pub storage_root: StorageRoot,
    /// Directory holding this device's RP pairing file + VPN settings.
    pub pairing_dir: PathBuf,
    /// Address of LocalDevVPN's reflector (default 10.7.0.1).
    pub tunnel_host: String,
    /// Machine name reported to Apple's developer portal.
    pub machine_name: String,
    /// Select the first team automatically (free accounts have exactly one).
    pub team_id: Option<String>,
}

/// A queued answer from Swift for a 2FA / certificate prompt.
#[derive(Debug, Clone)]
enum PromptAnswer {
    TwoFactor(TwoFactorCallbackResponse),
    Certificates(Option<Vec<String>>),
}

pub(crate) struct PromptBus {
    pending: Mutex<Vec<PromptAnswer>>,
    notify: Mutex<Option<NotifyCallback>>,
    // `AtomicPtr` keeps this bus Send + Sync so callback futures satisfy
    // isideload's `MaybeSend` bound. Swift owns the pointee for the session's
    // lifetime, which is guaranteed by the C ABI contract.
    ctx: std::sync::atomic::AtomicPtr<std::ffi::c_void>,
}

impl PromptBus {
    fn new() -> Self {
        Self {
            pending: Mutex::new(Vec::new()),
            notify: Mutex::new(None),
            ctx: std::sync::atomic::AtomicPtr::new(std::ptr::null_mut()),
        }
    }

    fn set_sink(&self, cb: NotifyCallback, ctx: *mut std::ffi::c_void) {
        *self.notify.lock().unwrap() = Some(cb);
        self.ctx.store(ctx, std::sync::atomic::Ordering::SeqCst);
    }

    fn emit(&self, kind: i32, payload: &str) {
        let guard = self.notify.lock().unwrap();
        if let Some(cb) = *guard {
            let ctx = self.ctx.load(std::sync::atomic::Ordering::SeqCst);
            cb(kind, payload.as_ptr() as *const i8, payload.len() as i32, ctx);
        }
    }

    fn progress(&self, value: f32) {
        self.emit(1, &(value.clamp(0.0, 1.0) * 100.0).to_string());
    }

    fn log(&self, line: &str) {
        self.emit(3, line);
    }

    fn push_answer(&self, answer: PromptAnswer) {
        self.pending.lock().unwrap().push(answer);
    }

    /// Non-blocking take; async callbacks poll with a short sleep.
    fn take_answer(&self) -> Option<PromptAnswer> {
        self.pending.lock().unwrap().pop()
    }
}

/// The session handle handed to Swift as an opaque pointer.
pub struct Session {
    config: SessionConfig,
    runtime: Runtime,
    bus: Arc<PromptBus>,
    cancelled: Arc<Mutex<bool>>,
    account: OnceLock<Mutex<AppleAccount>>,
    link: Option<DeviceLink>,
}

impl Session {
    pub fn new(config: SessionConfig) -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("failed to build runtime: {e}"))?;
        config.storage_root.ensure().map_err(|e| format!("storage: {e}"))?;
        Ok(Self {
            config,
            runtime,
            bus: Arc::new(PromptBus::new()),
            cancelled: Arc::new(Mutex::new(false)),
            account: OnceLock::new(),
            link: None,
        })
    }

    pub fn set_sink(&self, cb: NotifyCallback, ctx: *mut std::ffi::c_void) {
        self.bus.set_sink(cb, ctx);
    }

    /// Answer a pending prompt. `response` accepts:
    ///   - 2FA:   `code:123456`, `sms:1`, `devices`, `resend`, `abort`
    ///   - certs: `cert:<serial>,<serial>` or `none`
    pub fn respond(&self, response: &str) {
        let answer = if let Some(code) = response.strip_prefix("code:") {
            PromptAnswer::TwoFactor(TwoFactorCallbackResponse::SubmitCode(code.to_string()))
        } else if let Some(id) = response.strip_prefix("sms:") {
            PromptAnswer::TwoFactor(TwoFactorCallbackResponse::SendSms(
                id.parse().unwrap_or(0),
            ))
        } else if response == "devices" {
            PromptAnswer::TwoFactor(TwoFactorCallbackResponse::SendToDevices)
        } else if response == "resend" {
            PromptAnswer::TwoFactor(TwoFactorCallbackResponse::ResendCode)
        } else if response == "abort" {
            PromptAnswer::TwoFactor(TwoFactorCallbackResponse::Abort)
        } else if let Some(serials) = response.strip_prefix("cert:") {
            let list = serials
                .split(',')
                .map(|s| s.to_string())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>();
            PromptAnswer::Certificates(Some(list))
        } else if response == "none" {
            PromptAnswer::Certificates(None)
        } else {
            return;
        };
        self.bus.push_answer(answer);
    }

    pub fn cancel(&self) {
        *self.cancelled.lock().unwrap() = true;
        self.bus.push_answer(PromptAnswer::TwoFactor(TwoFactorCallbackResponse::Abort));
    }

    fn check_cancelled(&self) -> Result<(), String> {
        if *self.cancelled.lock().unwrap() {
            Err("cancelled".to_string())
        } else {
            Ok(())
        }
    }

    /// Step 1+2: log in with Apple ID (including 2FA) and open a developer session.
    pub fn sign_in(&mut self) -> Result<(), String> {
        self.check_cancelled()?;
        let cfg = self.config.clone();
        let bus = Arc::clone(&self.bus);
        let cancelled = Arc::clone(&self.cancelled);

        let account = self
            .runtime
            .block_on(async move {
                let provider = match &cfg.anisette_url {
                    Some(url) if !url.is_empty() => RemoteV3AnisetteProvider::new(
                        url,
                        Box::new(cfg.storage_root.clone().into_isideload_storage()),
                        "2".to_string(),
                    )?,
                    _ => RemoteV3AnisetteProvider::default()?
                        .set_serial_number("2".to_string())
                        .set_storage(Box::new(
                            cfg.storage_root.clone().into_isideload_storage(),
                        )),
                };

                // 2FA callback: emit a JSON prompt and wait for Swift's answer.
                let two_factor = async |params: TwoFactorCallbackParams| -> Result<TwoFactorCallbackResponse, Report> {
                    let payload = serde_json::to_string(&params)
                        .unwrap_or_else(|_| "{}".to_string());
                    bus.emit(0, &payload);
                    loop {
                        if *cancelled.lock().unwrap() {
                            return Ok(TwoFactorCallbackResponse::Abort);
                        }
                        if let Some(PromptAnswer::TwoFactor(resp)) = bus.take_answer() {
                            return Ok(resp);
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(60)).await;
                    }
                };

                let account = AppleAccount::builder(&cfg.apple_id)
                    .anisette_provider(provider)
                    .login(&cfg.app_password, two_factor)
                    .await?;
                Ok::<AppleAccount, Report>(account)
            })
            .map_err(|e: Report| {
                let msg = e.to_string();
                set_last_error(&msg);
                msg
            })?;

        self.account
            .set(Mutex::new(account))
            .map_err(|_| "account already initialized".to_string())?;
        self.bus.emit(1, "100");
        Ok(())
    }

    /// Step 3+: sign the IPA and install it on the local device.
    ///
    /// `ipa_path` is the unsigned IPA in the app's sandbox.
    pub fn sign_and_install(&mut self, ipa_path: &str) -> Result<(), String> {
        self.check_cancelled()?;
        if let Some(link) = self.link.take() {
            drop(link);
        }
        self.bus.progress(0.0);

        let cfg = self.config.clone();
        let bus = Arc::clone(&self.bus);
        let ipa = PathBuf::from(ipa_path);
        let account_slot = self
            .account
            .get()
            .ok_or_else(|| "not signed in; call sign_in first".to_string())?;

        self.runtime.block_on(async {
            // Establish the device link once; it is shared by sign + install.
            let mut link = DeviceLink::connect(
                &cfg.tunnel_host,
                &cfg.pairing_dir,
                &cfg.machine_name,
                Arc::clone(&bus),
            )
            .await?;
            bus.log("device link established");

            // Developer session from the logged-in Apple account.
            let dev_session = {
                let mut guard = account_slot
                    .lock()
                    .map_err(|_| "account lock poisoned".to_string())?;
                DeveloperSession::from_account(&mut *guard)
                    .await
                    .map_err(|e| {
                        let msg = e.to_string();
                        set_last_error(&msg);
                        msg
                    })?
            };

            let storage = cfg.storage_root.clone().into_isideload_storage();
            // Free Apple ID accounts have exactly one team, so First is correct.
            let team_selection = TeamSelection::First;

            let cert_prompt = {
                let bus = Arc::clone(&bus);
                async move |certs: Vec<isideload::dev::certificates::DevelopmentCertificate>| -> Result<Option<Vec<String>>, Report> {
                    let payload = serde_json::to_string(&certs)
                        .unwrap_or_else(|_| "[]".to_string());
                    bus.emit(2, &payload);
                    loop {
                        if let Some(PromptAnswer::Certificates(selection)) = bus.take_answer() {
                            return Ok(selection);
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(60)).await;
                    }
                }
            };

            let extensions_behavior = ExtensionsBehaviorSelection::<ExtensionsBehaviorCallbackBox>::Fixed(
                ExtensionsBehavior::RegisterAll,
            );
            let mut sideloader = SideloaderBuilder::new(dev_session, cfg.apple_id.clone())
                .team_selection(team_selection)
                .max_certs_behavior(MaxCertsBehavior::Prompt(cert_prompt))
                .extensions_behavior(extensions_behavior)
                .storage(Box::new(storage))
                .machine_name(cfg.machine_name.clone())
                .build();

            // Sign the app (produces a .app bundle in a temp dir).
            let progress_cb = {
                let bus = Arc::clone(&bus);
                async move |value: f32| bus.progress(value * 0.7)
            };
            let (signed_app, _special) = sideloader
                .sign_app(ipa, None, false, Some(progress_cb), None, link.udid())
                .await
                .map_err(|e| {
                    let msg = e.to_string();
                    set_last_error(&msg);
                    msg
                })?;
            bus.log("IPA re-signed with development certificate");
            bus.progress(0.75);

            // Install over the RSD tunnel.
            let install_progress = {
                let bus = Arc::clone(&bus);
                move |pct: u64| bus.progress(0.75 + (pct as f32 / 100.0) * 0.25)
            };
            link.install(&signed_app, install_progress).await?;

            bus.progress(1.0);
            bus.log("install complete");
            Ok::<(), String>(())
        })
    }
}
