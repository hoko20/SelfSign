import Foundation

// MARK: - Rust core config

struct SessionConfig: Codable, Sendable {
    let appleId: String
    let appPassword: String
    let anisetteURL: String?
    let storageRoot: String
    let pairingDir: String
    let tunnelHost: String
    let machineName: String
    let teamID: String?

    enum CodingKeys: String, CodingKey {
        case appleId = "apple_id"
        case appPassword = "app_password"
        case anisetteURL = "anisette_url"
        case storageRoot = "storage_root"
        case pairingDir = "pairing_dir"
        case tunnelHost = "tunnel_host"
        case machineName = "machine_name"
        case teamID = "team_id"
    }
}

// MARK: - 2FA payload (matches isideload's TwoFactorCallbackParams)

struct TwoFactorParams: Decodable, Sendable {
    let lastError: String?
    let unknown: Bool
    let sms: Bool
    let numbers: [TrustedNumber]
    let selectedNumberID: UInt32?

    enum CodingKeys: String, CodingKey {
        case lastError = "lastError"
        case unknown, sms, numbers
        case selectedNumberID = "selectedNumberId"
    }
}

struct TrustedNumber: Decodable, Sendable {
    let id: UInt32
    let numberWithDialCode: String

    enum CodingKeys: String, CodingKey {
        case id
        case numberWithDialCode = "numberWithDialCode"
    }
}

// MARK: - App library model

struct SignedApp: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let bundleID: String
    let version: String
    let ipaPath: String          // relative to Documents/Repos
    let signedAt: Date
    let expiresAt: Date          // signedAt + 7 days for free Apple ID
    let iconData: Data?

    var daysRemaining: Int {
        let days = Calendar.current.dateComponents([.day], from: .now, to: expiresAt).day ?? 0
        return max(0, days)
    }

    var isExpiringSoon: Bool { daysRemaining <= 2 }
}

// MARK: - Operation state

enum OperationPhase: Sendable {
    case idle
    case signingIn
    case awaiting2FA
    case registeringCertificate
    case signing
    case uploading
    case installing
    case done
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "就绪"
        case .signingIn: return "登录 Apple ID"
        case .awaiting2FA: return "等待双重认证"
        case .registeringCertificate: return "申请签名证书"
        case .signing: return "正在重签 IPA"
        case .uploading: return "上传应用到设备"
        case .installing: return "正在安装"
        case .done: return "完成"
        case .failed(let e): return "失败: \(e)"
        }
    }
}
