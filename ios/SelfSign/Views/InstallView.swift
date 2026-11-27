import SwiftUI

struct InstallView: View {
    @Environment(AppStore.self) private var store
    @State private var showingImport = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Status card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("签名状态", systemImage: "signature")
                            .font(.headline)
                        Spacer()
                        statusBadge
                    }
                    Text(store.phase.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ProgressView(value: store.progress, total: 100)
                        .tint(.blue)
                        .opacity(store.progress > 0 ? 1 : 0.35)

                    if let err = store.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))

                // Primary actions
                VStack(spacing: 12) {
                    Button {
                        showingImport = true
                    } label: {
                        Label("选择 IPA 并签名安装", systemImage: "square.and.arrow.down.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    Button {
                        Task { await store.refreshExpiringSoon() }
                    } label: {
                        Label("刷新即将过期的应用", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }

                // Signing account
                VStack(alignment: .leading, spacing: 10) {
                    Label("签名账号", systemImage: "person.crop.circle")
                        .font(.headline)
                    HStack {
                        Text(store.appleID.isEmpty ? "未登录" : store.appleID)
                            .foregroundStyle(store.appleID.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button(store.appleID.isEmpty ? "登录" : "更改") {
                            store.showingSignIn = true
                        }
                        .buttonStyle(.glass)
                    }
                    Text("免费 Apple ID 的签名有效期为 7 天，可通过快捷指令自动刷新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))

                // Log
                if !store.logLines.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("日志", systemImage: "doc.text")
                            .font(.headline)
                        ScrollView(.vertical) {
                            ForEach(store.logLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxHeight: 160)
                    }
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                }
            }
            .padding()
        }
        .navigationTitle("签名")
        .fileImporter(
            isPresented: $showingImport,
            allowedContentTypes: [.init(filenameExtension: "ipa")!],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first,
               url.startAccessingSecurityScopedResource() {
                Task {
                    await store.importAndInstall(url)
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch store.phase {
        case .idle:
            Label("就绪", systemImage: "circle").foregroundStyle(.secondary)
        case .done:
            Label("完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Label("失败", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        default:
            Label("进行中", systemImage: "progress.indicator").foregroundStyle(.blue)
        }
    }
}
