import SwiftUI

struct SignInView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var appleID = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue)
                        .glassEffect(.regular, in: .circle)

                    VStack(spacing: 6) {
                        Text("登录 Apple ID")
                            .font(.title2.bold())
                        Text("凭证仅保存在本机钥匙串，用于申请免费开发证书。不会上传到任何服务器。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        TextField("Apple ID (邮箱)", text: $appleID)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(14)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))

                        SecureField("App 专用密码", text: $password)
                            .textContentType(.password)
                            .padding(14)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    }

                    Button {
                        store.appleID = appleID
                        store.appPassword = password
                        dismiss()
                    } label: {
                        Text("保存").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(appleID.isEmpty || password.isEmpty)

                    Text("在 account.apple.com 生成「App 专用密码」，格式通常为 xxxx-xxxx-xxxx-xxxx。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                appleID = store.appleID
                password = store.appPassword
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 2FA prompt sheet shown when the Rust core emits kind=0.
struct TwoFactorSheet: View {
    @Environment(AppStore.self) private var store
    let params: TwoFactorParams
    @State private var code = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("双重认证")
                .font(.title2.bold())

            Text(promptText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("6 位验证码", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title2.monospaced())
                .multilineTextAlignment(.center)
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))

            Button {
                store.submit2FA(code)
            } label: {
                Text("验证").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(code.count < 6)

            HStack(spacing: 16) {
                Button("发送到设备") { store.send2FAtoDevices() }
                    .buttonStyle(.glass)
                Button("重新发送") { store.resend2FA() }
                    .buttonStyle(.glass)
                Button("取消") { store.cancelOperation() }
                    .buttonStyle(.glass)
            }
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .padding()
    }

    private var promptText: String {
        if params.sms, let id = params.selectedNumberID,
           let number = params.numbers.first(where: { $0.id == id }) {
            return "验证码已发送至 \(number.numberWithDialCode)"
        }
        if params.unknown {
            return "请选择验证方式：输入验证码，或发送到受信任设备。"
        }
        return "请输入受信任设备显示的验证码。"
    }
}

/// Certificate limit prompt (free accounts allow 2 certificates).
struct CertificateLimitSheet: View {
    @Environment(AppStore.self) private var store
    let serials: [String]
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "certificate")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("证书数量已达上限")
                .font(.title2.bold())
            Text("免费 Apple ID 最多同时拥有 2 个开发证书。选择要吊销的证书以继续。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ForEach(serials, id: \.self) { serial in
                Button {
                    if selected.contains(serial) { selected.remove(serial) }
                    else { selected.insert(serial) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(serial) ? "checkmark.circle.fill" : "circle")
                        Text(serial).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
                .buttonStyle(.glass)
            }

            HStack(spacing: 12) {
                Button("取消") { store.cancelOperation() }
                    .buttonStyle(.glass)
                Button("吊销并继续") { store.respondCert(Array(selected)) }
                    .buttonStyle(.glassProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .padding()
    }
}
