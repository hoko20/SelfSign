import Foundation
import Observation
import UIKit

/// Handles `selfsign://` URLs from Shortcuts / x-callback-url.
///
/// Supported actions:
///   selfsign://refresh                     -> refresh apps expiring within 2 days
///   selfsign://refresh?bundle=<id>         -> refresh one app by bundle id
///   selfsign://refresh?all=1               -> refresh every signed app
///   selfsign://status                      -> report current signing status
///
/// x-callback-url (optional):
///   selfsign://refresh?x-success=<url>&x-error=<url>&x-cancel=<url>
/// On completion the app opens the corresponding callback with `?result=...`.
@MainActor
@Observable
final class ShortcutRouter {
    static let shared = ShortcutRouter()

    /// Set by the root view so the router can post banners.
    weak var store: AppStore?

    private var callbacks: [String: String] = [:]
    private var lastAction: String = ""

    private init() {}

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "selfsign" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let action = (components?.host ?? "refresh").lowercased()
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap {
            item -> (String, String)? in guard let v = item.value else { return nil }
            return (item.name, v)
        })
        callbacks = [
            "success": query["x-success"] ?? "",
            "error": query["x-error"] ?? "",
            "cancel": query["x-cancel"] ?? "",
        ]
        lastAction = action

        switch action {
        case "refresh":
            let bundle = query["bundle"]
            let all = query["all"] == "1"
            Task {
                guard let store else { return }
                if let bundle {
                    guard let app = store.apps.first(where: { $0.bundleID == bundle }) else {
                        fireError("未找到应用: \(bundle)")
                        return
                    }
                    await store.refresh(app)
                } else if all {
                    for app in store.apps { await store.refresh(app) }
                } else {
                    await store.refreshExpiringSoon()
                }
                finish()
            }
        case "status":
            fireSuccess("status=\(store?.phase.label ?? "idle")")
        default:
            fireError("未知操作: \(action)")
        }
    }

    private func finish() {
        guard let store else { return }
        switch store.phase {
        case .done:
            fireSuccess("refreshed=\(store.apps.count)")
        case .failed(let message):
            fireError(message)
        default:
            break
        }
    }

    private func fireSuccess(_ result: String) {
        openCallback("success", result: result)
    }
    private func fireError(_ message: String) {
        openCallback("error", result: message)
    }
    private func fireCancel() {
        openCallback("cancel", result: "cancelled")
    }

    private func openCallback(_ key: String, result: String) {
        guard let base = callbacks[key], !base.isEmpty, let url = URL(string: base) else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encoded = result.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? result
        components?.queryItems = (components?.queryItems ?? []) + [
            URLQueryItem(name: "result", value: encoded)
        ]
        if let final = components?.url {
            UIApplication.shared.open(final)
        }
    }
}
