import Foundation
import NetworkExtension
import Observation

/// Manages the built-in packet-tunnel extension (no companion App needed).
/// Adapted from SiamSadik/LocalDevVPN's TunnelManager, trimmed to what
/// SelfSign needs: ensure the reflector is connected before signing.
@MainActor
@Observable
final class TunnelManager {
    static let shared = TunnelManager()

    enum Status: Sendable {
        case disconnected, connecting, connected, disconnecting, error

        var label: String {
            switch self {
            case .disconnected: return "未连接"
            case .connecting: return "连接中"
            case .connected: return "已连接"
            case .disconnecting: return "断开中"
            case .error: return "错误"
            }
        }
        var systemImage: String {
            switch self {
            case .disconnected: return "network.slash"
            case .connecting: return "network.badge.shield.half.filled"
            case .connected: return "checkmark.shield.fill"
            case .disconnecting: return "network.badge.shield.half.filled"
            case .error: return "exclamationmark.shield.fill"
            }
        }
    }

    private(set) var status: Status = .disconnected
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var loaded = false

    private var tunnelBundleID: String {
        guard let main = Bundle.main.bundleIdentifier else { return "com.selfsign.app.TunnelProv" }
        return main + ".TunnelProv"
    }
    private var deviceIP: String {
        UserDefaults.standard.string(forKey: "tunnel_device_ip") ?? "10.7.0.0"
    }
    private var fakeIP: String {
        UserDefaults.standard.string(forKey: "tunnel_fake_ip") ?? "10.7.0.1"
    }

    private init() {
        Task { await load() }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let connection = note.object as? NEVPNConnection else { return }
            Task { @MainActor in
                self?.updateStatus(connection.status)
            }
        }
    }

    // MARK: - Load / configure

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let ours = managers.filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == tunnelBundleID
            }
            if let existing = ours.first {
                manager = existing
                updateStatus(existing.connection.status)
            }
            loaded = true
        } catch {
            status = .error
            loaded = true
        }
    }

    private func ensureManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == tunnelBundleID
        }) {
            manager = existing
            return existing
        }

        let newManager = NETunnelProviderManager()
        newManager.localizedDescription = "SelfSign Local Tunnel"
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleID
        proto.serverAddress = "SelfSign Local Network Tunnel"
        newManager.protocolConfiguration = proto

        let rule = NEOnDemandRuleEvaluateConnection()
        rule.interfaceTypeMatch = .any
        rule.connectionRules = [NEEvaluateConnectionRule(
            matchDomains: [deviceIP, fakeIP], andAction: .connectIfNeeded
        )]
        newManager.onDemandRules = [rule]
        newManager.isOnDemandEnabled = true
        newManager.isEnabled = true

        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()
        manager = newManager
        return newManager
    }

    // MARK: - Start / stop

    /// Ensure the reflector is connected. Called automatically before signing.
    func ensureConnected() async throws {
        if !loaded { await load() }
        let mgr = try await ensureManager()
        switch mgr.connection.status {
        case .connected:
            status = .connected
            return
        case .connecting:
            status = .connecting
            try await waitUntilConnected(timeout: 10)
            return
        default:
            break
        }
        try await start()
    }

    func start() async throws {
        let mgr = try await ensureManager()
        mgr.isEnabled = true
        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()

        if mgr.connection.status == .connected { status = .connected; return }

        let options: [String: NSObject] = [
            "TunnelDeviceIP": deviceIP as NSObject,
            "TunnelFakeIP": fakeIP as NSObject,
            "TunnelSubnetMask": "255.255.255.255" as NSObject,
        ]
        do {
            try mgr.connection.startVPNTunnel(options: options)
            status = .connecting
            try await waitUntilConnected(timeout: 10)
        } catch {
            status = .error
            throw error
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
        status = .disconnecting
    }

    private func waitUntilConnected(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if manager?.connection.status == .connected {
                status = .connected
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        if manager?.connection.status != .connected {
            status = .error
            throw NSError(
                domain: "com.selfsign.tunnel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "内置隧道连接超时，请检查网络权限"]
            )
        }
    }

    private func updateStatus(_ s: NEVPNStatus) {
        switch s {
        case .invalid, .disconnected: status = .disconnected
        case .connecting, .reasserting: status = .connecting
        case .connected: status = .connected
        case .disconnecting: status = .disconnecting
        @unknown default: status = .error
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
