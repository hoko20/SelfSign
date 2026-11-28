import Foundation

/// Swift-side mirror of the `selfsign-core` C ABI.
/// Every blocking entry point is wrapped in `Task.detached(priority: .userInitiated)`.

enum RustBridgeError: LocalizedError {
    case sessionCreationFailed(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed(let m), .operationFailed(let m): return m
        }
    }
}

/// Events emitted by the Rust core through `NotifyCallback`.
enum CoreEvent: Sendable {
    case twoFactor(String)     // JSON: TwoFactorCallbackParams
    case progress(Double)      // 0...100
    case certLimit([String])   // serial numbers
    case log(String)
}

final class CoreSession: @unchecked Sendable {
    typealias Handle = OpaquePointer

    private let handle: Handle
    private let eventHandler: @Sendable (CoreEvent) -> Void

    /// C callback trampoline. `ctx` carries the session object via Unmanaged.
    private static let callback: @convention(c) (
        Int32, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?
    ) -> Void = { kind, ptr, len, ctx in
        guard let ctx else { return }
        let session = Unmanaged<CoreSession>.fromOpaque(ctx).takeUnretainedValue()
        let payload: String
        if let ptr, len > 0 {
            payload = String(decoding: Data(bytes: ptr, count: Int(len)), as: UTF8.self)
        } else {
            payload = ""
        }
        switch kind {
        case 0: session.eventHandler(.twoFactor(payload))
        case 1: session.eventHandler(.progress(Double(payload) ?? 0))
        case 2:
            let serials = (try? JSONDecoder().decode([String].self, from: Data(payload.utf8))) ?? []
            session.eventHandler(.certLimit(serials))
        case 3: session.eventHandler(.log(payload))
        default: break
        }
    }

    init(config: SessionConfig, eventHandler: @escaping @Sendable (CoreEvent) -> Void) throws {
        self.eventHandler = eventHandler
        let json = try JSONEncoder().encode(config)
        let jsonString = String(decoding: json, as: UTF8.self)
        guard let handle = jsonString.withCString({ ss_session_new($0) }) else {
            throw RustBridgeError.sessionCreationFailed(CoreSession.lastError())
        }
        self.handle = handle
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        ss_session_set_callback(handle, Self.callback, ctx)
    }

    deinit {
        ss_session_free(handle)
    }

    // MARK: - Async wrappers

    func signIn() async throws {
        let handle = self.handle
        try await Task.detached(priority: .userInitiated) {
            if ss_sign_in(handle) != 0 {
                throw RustBridgeError.operationFailed(CoreSession.lastError())
            }
        }.value
    }

    func signAndInstall(ipaPath: String) async throws {
        let handle = self.handle
        try await Task.detached(priority: .userInitiated) {
            if ipaPath.withCString({ ss_sign_install(handle, $0) }) != 0 {
                throw RustBridgeError.operationFailed(CoreSession.lastError())
            }
        }.value
    }

    func respond(_ answer: String) {
        answer.withCString { ss_respond(handle, $0) }
    }

    func cancel() {
        ss_cancel(handle)
    }

    // MARK: - Error helpers

    static func lastError() -> String {
        guard let ptr = ss_take_error() else { return "Unknown error" }
        defer { ss_string_free(ptr) }
        return String(cString: ptr)
    }
}

// MARK: - C function declarations

@_silgen_name("ss_init")
private func ss_init() -> Int32

/// Process-wide one-time init. Call once from App.onAppear.
func selfSignInit() {
    _ = ss_init()
}

@_silgen_name("ss_last_error")
private func ss_last_error(_ buf: UnsafeMutablePointer<CChar>, _ len: Int32) -> Int32

@_silgen_name("ss_session_new")
private func ss_session_new(_ configJSON: UnsafePointer<CChar>) -> OpaquePointer?

@_silgen_name("ss_session_set_callback")
private func ss_session_set_callback(
    _ session: OpaquePointer,
    _ cb: @convention(c) (Int32, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) -> Int32

@_silgen_name("ss_sign_in")
private func ss_sign_in(_ session: OpaquePointer) -> Int32

@_silgen_name("ss_sign_install")
private func ss_sign_install(_ session: OpaquePointer, _ ipaPath: UnsafePointer<CChar>) -> Int32

@_silgen_name("ss_respond")
private func ss_respond(_ session: OpaquePointer, _ answer: UnsafePointer<CChar>) -> Int32

@_silgen_name("ss_cancel")
private func ss_cancel(_ session: OpaquePointer) -> Int32

@_silgen_name("ss_session_free")
private func ss_session_free(_ session: OpaquePointer)

@_silgen_name("ss_take_error")
private func ss_take_error() -> UnsafeMutablePointer<CChar>?

@_silgen_name("ss_string_free")
private func ss_string_free(_ s: UnsafeMutablePointer<CChar>?)

@_silgen_name("ss_pair_start")
private func ss_pair_start(
    _ pairingDir: UnsafePointer<CChar>,
    _ displayName: UnsafePointer<CChar>,
    _ machineModel: UnsafePointer<CChar>,
    _ pinCallback: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) -> Int32

/// iOS 27+ on-device pairing. Calls the blocking Rust pairable-host on a
/// background queue, streams the 6-digit PIN back through `onPin`, and returns
/// when the device has completed pair-setup and the pairing file is written.
func startOnDevicePairing(
    pairingDir: String,
    onPin: @escaping @Sendable (String) -> Void
) async throws {
    // Box the Swift closure so the C callback can reach it.
    final class PinBox {
        let handler: @Sendable (String) -> Void
        init(_ h: @escaping @Sendable (String) -> Void) { handler = h }
    }
    let box = PinBox(onPin)
    let ctx = Unmanaged.passUnretained(box).toOpaque()

    let callback: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Void = { ptr, len, rawCtx in
        guard let ptr, let rawCtx, len > 0 else { return }
        let pin = String(decoding: Data(bytes: ptr, count: Int(len)), as: UTF8.self)
        let box = Unmanaged<PinBox>.fromOpaque(rawCtx).takeUnretainedValue()
        box.handler(pin)
    }

    try await Task.detached(priority: .userInitiated) {
        let result = pairingDir.withCString { dir in
            "SelfSign".withCString { name in
                "Mac17,7".withCString { model in
                    ss_pair_start(dir, name, model, callback, ctx)
                }
            }
        }
        if result != 0 {
            throw RustBridgeError.operationFailed(CoreSession.lastError())
        }
        _ = box // keep alive across the blocking call
    }.value
}
