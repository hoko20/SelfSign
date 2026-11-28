import SwiftUI

/// iOS 27+ on-device pairing guide.
///
/// On iOS 27 the device can pair to a *pairable host* without any computer.
/// SelfSign advertises `_remotepairing-pairable-host._tcp`, shows a 6-digit PIN,
/// and the user confirms in Settings → Developer Mode. This view drives that
/// flow through `startOnDevicePairing` and explains the manual pairing-file
/// route for iOS 26.
struct PairingView: View {
    @Environment(AppStore.self) private var store
    @State private var pin: String?
    @State private var isPairing = false
    @State private var status: String = ""
    @State private var showGuide = false

    private let requiresIOS27 = true

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                if isPairing {
                    pinCard
                }
                stepsCard
                iOS26Fallback
            }
            .padding(20)
        }
        .navigationTitle("设备配对")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showGuide = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
            }
        }
        .sheet(isPresented: $showGuide) { PairingHelpSheet() }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 64, height: 64)
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            Text("免电脑配对")
                .font(.title2.bold())
            Text("iOS 27+ 直接在手机上生成配对文件，无需数据线或另一台设备。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await beginPairing() }
            } label: {
                Label(isPairing ? "正在等待配对…" : "开始端侧配对", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(isPairing)
            .padding(.top, 4)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - PIN display

    private var pinCard: some View {
        VStack(spacing: 10) {
            Text("在设备上输入此配对码")
                .font(.headline)
            if let pin {
                HStack(spacing: 8) {
                    ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                        Text(String(digit))
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .frame(width: 46, height: 56)
                            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            } else {
                ProgressView()
                    .frame(height: 56)
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("取消") {
                isPairing = false
                pin = nil
            }
            .buttonStyle(.glass)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Steps

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("操作步骤", systemImage: "list.number")
                .font(.headline)
            step(1, "点击「开始端侧配对」，SelfSign 开始广播配对服务。")
            step(2, "打开 设置 → 隐私与安全性 → 开发者模式。")
            step(3, "选择「配对这台 iPhone」，找到 SelfSign 并输入屏幕上的 6 位码。")
            step(4, "配对成功后返回此页，配对文件已自动保存，可直接签名安装。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - iOS 26 fallback

    private var iOS26Fallback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("iOS 26 及更早系统", systemImage: "info.circle")
                .font(.headline)
            Text("iOS 26 的配对必须由设备与主机双向握手完成。可用自己的电脑生成一次配对文件（iLoader / idevice_pair），再在设置中导入；或使用在线配对服务（借服务器主机）。之后即可永久免电脑续签。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                PairingFileImportView()
            } label: {
                Label("导入配对文件", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Actions

    private func beginPairing() async {
        isPairing = true
        pin = nil
        status = "正在广播配对服务，等待设备连接…"
        do {
            try await startOnDevicePairing(pairingDir: store.pairingDir.path) { code in
                Task { @MainActor in
                    pin = code
                    status = "在「设置 → 开发者模式」中输入此配对码"
                }
            }
            status = "配对成功！配对文件已保存。"
            try? await Task.sleep(for: .seconds(2))
            isPairing = false
            pin = nil
        } catch {
            status = "配对失败：\(error.localizedDescription)"
            isPairing = false
        }
    }
}

/// Simple pairing-file importer (copies a selected plist into the pairing dir).
struct PairingFileImportView: View {
    @Environment(AppStore.self) private var store
    @State private var showImporter = false
    @State private var message = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("导入配对文件")
                .font(.title2.bold())
            Text("选择 pairingFile.plist / .mobiledevicepairing 文件，复制到 SelfSign 的配对目录。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("选择文件") { showImporter = true }
                .buttonStyle(.glassProminent)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .navigationTitle("导入配对文件")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .propertyList]) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                let dest = store.pairingDir.appendingPathComponent("pairingFile.plist")
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: url, to: dest)
                    message = "导入成功：\(dest.lastPathComponent)"
                } catch {
                    message = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                message = "\(error.localizedDescription)"
            }
        }
    }
}

struct PairingHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("关于设备配对", systemImage: "questionmark.circle.fill")
                        .font(.title2.bold())
                    Text("配对文件是设备与主机之间的双向信任凭证，包含设备私钥签名。它让 SelfSign 能通过本机隧道与 iOS 安装服务通信，从而在手机上完成签名与安装。")
                    Text("iOS 27+ 支持设备端自助配对（本机生成，零电脑）。iOS 26 需先借一次电脑或在线服务生成配对文件，之后永久免电脑续签。")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("配对说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
