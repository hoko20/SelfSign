import SwiftUI

/// LiveContainer integration view.
///
/// LiveContainer is bundled as full source under `third_party/LiveContainer`
/// and shipped as a separate IPA artifact. Once installed (signed by SelfSign),
/// it lets the user run unlimited side-loaded apps inside a single App ID,
/// bypassing the free-account 3-app / 10-app-id limit.
struct ContainerView: View {
    @Environment(AppStore.self) private var store
    @State private var containerInstalled = false
    @State private var showGuide = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroCard
                featureGrid
                workflowCard
                if !containerInstalled {
                    installHintCard
                }
            }
            .padding(20)
        }
        .navigationTitle("容器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showGuide = true
                } label: {
                    Image(systemName: "book.circle")
                }
            }
        }
        .sheet(isPresented: $showGuide) { ContainerGuideSheet() }
        .onAppear { detectContainer() }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [.blue.opacity(0.7), .purple.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 68, height: 68)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("LiveContainer")
                .font(.title2.bold())
            Text("一个 App 运行无限应用")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: containerInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(containerInstalled ? .green : .secondary)
                Text(containerInstalled ? "已检测到容器" : "尚未安装容器")
                    .font(.subheadline)
            }

            if containerInstalled {
                Link(destination: URL(string: "livecontainer://")!) {
                    Label("打开 LiveContainer", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Features

    private let features: [(String, String, String)] = [
        ("infinity.circle", "无限应用", "免费账号 3 App 限制不再适用"),
        ("square.on.square", "多开共存", "同 App 多版本、多数据容器"),
        ("bolt.fill", "JIT / JIT-less", "按需启用 JIT 加速"),
        ("wrench.and.screwdriver.fill", "Tweak 注入", "内置动态库 tweak 加载器"),
        ("icloud.and.arrow.down", "AltStore 源", "直接从源安装 IPA"),
        ("puzzlepiece.extension", "插件支持", "LivePlugIn / ExtensionKit")
    ]

    private var featureGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(features, id: \.0) { icon, title, subtitle in
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.subheadline.bold())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    // MARK: - Workflow

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("使用流程", systemImage: "arrow.triangle.branch")
                .font(.headline)
            Text("1. 在「签名」页选择 LiveContainer IPA 并签名安装。")
            Text("2. 打开 LiveContainer，导入任意 IPA（本地文件或 AltStore 源）。")
            Text("3. 在容器内直接运行，所有 App 共享 SelfSign 的签名证书。")
            Text("4. 用快捷指令刷新 SelfSign 签名，容器内所有 App 一并续期。")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var installHintCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("如何安装容器", systemImage: "lightbulb")
                .font(.headline)
            Text("CI 每次构建会同时产出 LiveContainer.ipa。下载后回到「签名」页导入它，用你的 Apple ID 签名安装即可。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                InstallView()
            } label: {
                Label("前往签名安装", systemImage: "signature")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func detectContainer() {
        let apps = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        // Detect via URL scheme registration (best-effort).
        containerInstalled = UIApplication.shared.canOpenURL(URL(string: "livecontainer://")!)
    }
}

struct ContainerGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("LiveContainer 容器", systemImage: "square.stack.3d.up.fill")
                        .font(.title2.bold())
                    Text("LiveContainer 是一个完整的开源项目（AGPL-3.0），已作为全功能源码内置在 SelfSign 工程的 third_party/LiveContainer/ 目录，并随 CI 一起构建为独立 IPA。")
                    Text("它不是一个简化版：MachO 加载、dyld 校验绕过、Tweak 注入、多容器隔离、AltStore 源等全部功能均保留。")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("关于容器")
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
