import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ShortcutGuideView()
                } label: {
                    Label("快捷指令刷新", systemImage: "bolt.fill")
                }
                NavigationLink {
                    PairingGuideView()
                } label: {
                    Label("设备配对 / LocalDevVPN", systemImage: "link.circle.fill")
                }
            } header: {
                Text("指南")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Anisette 服务器 URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://…/v3", text: Bindable(store).anisetteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("LocalDevVPN 反射地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("10.7.0.1", text: Bindable(store).tunnelHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                }
                .padding(.vertical, 4)
            } header: {
                Text("高级")
            } footer: {
                Text("留空使用默认 anisette 服务器。2026 年 10 月后请选用 windows-ADI 实现的 anisette-v3 服务。")
            }

            Section {
                HStack {
                    Text("存储目录")
                    Spacer()
                    Text(store.appSupport.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                HStack {
                    Text("已签名应用")
                    Spacer()
                    Text("\(store.apps.count)").foregroundStyle(.secondary)
                }
            } header: {
                Text("关于")
            }
        }
        .navigationTitle("设置")
    }
}

struct ShortcutGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("无需电脑，刷新签名", systemImage: "bolt.fill")
                    .font(.title2.bold())

                Text("在「快捷指令」App 中创建一个 URL 操作，填入下面的地址即可触发刷新。可以把它加到主屏幕或自动化中。")
                    .font(.subheadline)

                VStack(alignment: .leading, spacing: 8) {
                    Text("刷新所有即将过期应用").font(.headline)
                    CodeBlock("selfsign://refresh")
                    Text("刷新全部应用").font(.headline)
                    CodeBlock("selfsign://refresh?all=1")
                    Text("刷新指定 Bundle ID").font(.headline)
                    CodeBlock("selfsign://refresh?bundle=com.example.app")
                    Text("支持 x-callback-url").font(.headline)
                    CodeBlock("selfsign://refresh?x-success=shortcuts://&x-error=shortcuts://")
                }
            }
            .padding()
        }
        .navigationTitle("快捷指令")
    }
}

struct PairingGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("设备配对", systemImage: "link.circle.fill")
                    .font(.title2.bold())
                Text("""
                SelfSign 内置了 LocalDevVPN 的报文反射隧道（来源：SiamSadik/LocalDevVPN，MIT），
                无需另外安装任何 App，也不需要数据线。签名时会自动启动隧道。

                1. 首次使用需在系统弹窗中允许添加 VPN 配置。
                2. 生成或导入配对文件 rp_pairing_file.plist 到：
                   Application Support/selfsign/pairings/
                3. iOS 27+ 支持在「设置 → 隐私与安全性 → 开发者模式」中直接配对。
                4. 隧道地址默认是 10.7.0.0 / 10.7.0.1，可在「高级」中修改。
                """)
                .font(.subheadline)
                .textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("配对指南")
    }
}

private struct CodeBlock: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
