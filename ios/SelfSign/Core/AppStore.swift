import Foundation
import Observation
import SwiftUI

/// Central observable state. Owns credentials (Keychain), the signed-app
/// library (JSON in Application Support), and the active Rust session.
@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    // MARK: - Published state

    var phase: OperationPhase = .idle
    var progress: Double = 0
    var logLines: [String] = []
    var apps: [SignedApp] = []
    var twoFactorPrompt: TwoFactorParams?
    var certPrompt: [String]?
    var showingSignIn = false
    var lastError: String?

    // Credentials (stored in Keychain, never in UserDefaults)
    var appleID: String = "" {
        didSet { if !appleID.isEmpty { Keychain.save(appleID, for: "apple_id") } }
    }
    var appPassword: String = "" {
        didSet { if !appPassword.isEmpty { Keychain.save(appPassword, for: "app_password") } }
    }
    var anisetteURL: String = "" {
        didSet { UserDefaults.standard.set(anisetteURL, forKey: "anisette_url") }
    }
    var tunnelHost: String = "10.7.0.1" {
        didSet { UserDefaults.standard.set(tunnelHost, forKey: "tunnel_host") }
    }

    private var session: CoreSession?
    private var pendingIPA: URL?

    // MARK: - Paths

    lazy var appSupport: URL = {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("selfsign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var storageRoot: URL { appSupport.appendingPathComponent("storage", isDirectory: true) }
    var pairingDir: URL { appSupport.appendingPathComponent("pairings", isDirectory: true) }
    var reposDir: URL { appSupport.appendingPathComponent("repos", isDirectory: true) }
    private var libraryFile: URL { appSupport.appendingPathComponent("library.json") }

    private init() {
        appleID = Keychain.load("apple_id") ?? ""
        appPassword = Keychain.load("app_password") ?? ""
        anisetteURL = UserDefaults.standard.string(forKey: "anisette_url") ?? ""
        tunnelHost = UserDefaults.standard.string(forKey: "tunnel_host") ?? "10.7.0.1"
        for dir in [storageRoot, pairingDir, reposDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        loadLibrary()
    }

    // MARK: - Configuration

    private func makeConfig() -> SessionConfig {
        SessionConfig(
            appleId: appleID,
            appPassword: appPassword,
            anisetteURL: anisetteURL.isEmpty ? nil : anisetteURL,
            storageRoot: storageRoot.path,
            pairingDir: pairingDir.path,
            tunnelHost: tunnelHost,
            machineName: "SelfSign",
            teamID: nil
        )
    }

    // MARK: - Event handling

    private func handle(_ event: CoreEvent) {
        switch event {
        case .progress(let value):
            progress = value
            if value > 0 && value < 30 { phase = .signing }
            else if value >= 30 && value < 75 { phase = .uploading }
            else if value >= 75 && value < 100 { phase = .installing }
        case .twoFactor(let json):
            twoFactorPrompt = try? JSONDecoder().decode(TwoFactorParams.self, from: Data(json.utf8))
            phase = .awaiting2FA
        case .certLimit(let serials):
            certPrompt = serials
        case .log(let line):
            logLines.append(line)
            if logLines.count > 200 { logLines.removeFirst() }
        }
    }

    // MARK: - Install flow

    /// Import an IPA from Files, then sign + install it.
    func importAndInstall(_ url: URL) async {
        lastError = nil
        logLines = []
        guard appleID.count > 0, appPassword.count > 0 else {
            phase = .failed("请先登录 Apple ID")
            showingSignIn = true
            return
        }
        let sandboxIPA = reposDir.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: sandboxIPA.path) {
                try FileManager.default.removeItem(at: sandboxIPA)
            }
            try FileManager.default.copyItem(at: url, to: sandboxIPA)
        } catch {
            phase = .failed("导入 IPA 失败: \(error.localizedDescription)")
            return
        }
        pendingIPA = sandboxIPA
        await runInstall(ipa: sandboxIPA, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Sign + install an app already in the library (used by Shortcuts refresh).
    func refresh(_ app: SignedApp) async {
        let ipa = reposDir.appendingPathComponent(app.ipaPath)
        guard FileManager.default.fileExists(atPath: ipa.path) else {
            phase = .failed("找不到原始 IPA: \(app.name)")
            return
        }
        await runInstall(ipa: ipa, name: app.name, updating: app.id)
    }

    /// Refresh every app expiring within 2 days (Shortcuts "refresh all").
    func refreshExpiringSoon() async {
        let targets = apps.filter { $0.isExpiringSoon }
        guard !targets.isEmpty else {
            phase = .done
            return
        }
        for app in targets {
            await refresh(app)
            if case .failed = phase { break }
        }
    }

    private func runInstall(ipa: URL, name: String, updating: UUID? = nil) async {
        phase = .signingIn
        progress = 0
        do {
            // Built-in LocalDevVPN reflector: no companion App required.
            logLines.append("启动内置本地隧道…")
            try await TunnelManager.shared.ensureConnected()
            logLines.append("内置本地隧道已连接")

            let session = try CoreSession(config: makeConfig(), eventHandler: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            })
            self.session = session
            try await session.signIn()
            phase = .registeringCertificate
            try await session.signAndInstall(ipaPath: ipa.path)

            let now = Date()
            let entry = SignedApp(
                id: updating ?? UUID(),
                name: name,
                bundleID: extractBundleID(from: ipa) ?? "unknown",
                version: extractVersion(from: ipa) ?? "1.0",
                ipaPath: ipa.lastPathComponent,
                signedAt: now,
                expiresAt: Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now,
                iconData: nil
            )
            if let index = apps.firstIndex(where: { $0.id == entry.id }) {
                apps[index] = entry
            } else {
                apps.insert(entry, at: 0)
            }
            saveLibrary()
            phase = .done
            progress = 100
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            phase = .failed(msg)
        }
    }

    // MARK: - 2FA response

    func submit2FA(_ code: String) {
        session?.respond("code:\(code)")
        twoFactorPrompt = nil
        phase = .registeringCertificate
    }
    func send2FAtoDevices() {
        session?.respond("devices")
        twoFactorPrompt = nil
    }
    func resend2FA() {
        session?.respond("resend")
    }
    func respondCert(_ serials: [String]) {
        session?.respond(serials.isEmpty ? "none" : "cert:\(serials.joined(separator: ","))")
        certPrompt = nil
    }
    func cancelOperation() {
        session?.cancel()
        twoFactorPrompt = nil
        certPrompt = nil
        phase = .idle
    }

    // MARK: - Library persistence

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryFile),
              let decoded = try? JSONDecoder().decode([SignedApp].self, from: data) else { return }
        apps = decoded
    }
    private func saveLibrary() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: libraryFile)
    }

    func deleteApp(_ app: SignedApp) {
        apps.removeAll { $0.id == app.id }
        try? FileManager.default.removeItem(at: reposDir.appendingPathComponent(app.ipaPath))
        saveLibrary()
    }

    // MARK: - IPA metadata (best-effort, no full unzip needed for display)

    private func extractBundleID(from ipa: URL) -> String? {
        guard let plist = readInfoPlist(from: ipa) else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }
    private func extractVersion(from ipa: URL) -> String? {
        guard let plist = readInfoPlist(from: ipa) else { return nil }
        return (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
    }
    private func readInfoPlist(from ipa: URL) -> [String: Any]? {
        // Lightweight: look for Info.plist via `unzip -p`-like enumeration is
        // expensive on iOS; the Rust core reads it during sign. Here we just
        // return nil and let the display use the file name.
        nil
    }
}

// MARK: - Keychain helper

enum Keychain {
    static func save(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.selfsign.app",
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.selfsign.app",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
