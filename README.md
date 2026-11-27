# SelfSign

用**个人 Apple ID（免费账号）**在 iPhone 上直接给 IPA 签名并安装的应用，iOS 26.0+ 专属，全量 Liquid Glass 液态玻璃 UI。

- Apple ID 登录（含 2FA）→ 申请免费开发证书 → 重签 IPA → 安装到本机
- **内置 LocalDevVPN 报文反射隧道**，无需另装 App、无需数据线
- **快捷指令刷新**：URL Scheme 触发重签重装，支持 x-callback-url
- **GitHub 推送即构建**：push 到 main 自动产出 IPA

## 技术来源

| 组件 | 来源 | 用途 |
|---|---|---|
| [isideload](https://github.com/nab138/isideload) | MIT | Apple ID 登录 / 2FA / 证书 / 描述文件 / zsign 重签 |
| [idevice](https://github.com/jkcoxson/idevice) | MIT | RemotePairing / TLS-PSK / CDTunnel / jktcp / AFC / installation_proxy |
| [LocalDevVPN](https://github.com/SiamSadik/LocalDevVPN) | MIT | 内置 NEPacketTunnelProvider 报文反射 |

## 目录结构

```
SelfSign/
├── core/                      # Rust 静态库（FFI 给 Swift）
│   ├── Cargo.toml
│   └── src/{lib,error,storage,session,tunnel,ffi}.rs
├── ios/
│   ├── project.yml            # XcodeGen 规格
│   ├── SelfSign/              # 主 App（SwiftUI + Liquid Glass）
│   │   ├── SelfSignApp.swift
│   │   ├── Views/             # 应用库/签名/设置/2FA
│   │   └── Core/              # FFI 桥接/状态/快捷指令/隧道管理
│   ├── TunnelProv/            # 内置 packet-tunnel 扩展
│   └── Info.plist 等
├── scripts/build-local.sh
└── .github/workflows/build.yml
```

## 构建（GitHub 推送即构建）

1. Fork / push 到 `main`（或打 `v*` tag）。
2. GitHub Actions 自动：`cargo build --target aarch64-apple-ios` → XcodeGen → xcodebuild archive → ad-hoc 签名 → 产出 `SelfSign-adhoc.ipa` artifact。
3. tag 构建会把 IPA 附加到 Release。

本地构建（需 macOS + Xcode + Rust）：

```bash
bash scripts/build-local.sh
```

## 首次使用

1. 安装 IPA（AltStore / 爱思 / 任意侧载工具）。
2. 打开 App → 「设置」→ 登录 Apple ID（需 App 专用密码）。
3. 准备配对文件 `rp_pairing_file.plist`：
   - iOS 27+：系统「设置 → 隐私与安全性 → 开发者模式 → 配对」直接生成；
   - iOS 26：用电脑端 `iloader` 或 `idevice_pair` 生成一次，导入到
     `Application Support/selfsign/pairings/`。
4. 「签名」→ 选 IPA → 自动启动内置隧道 → 登录 →（如需）2FA → 签名安装。
5. 免费 Apple ID 签名 7 天有效，用快捷指令刷新。

## 快捷指令

| URL | 作用 |
|---|---|
| `selfsign://refresh` | 刷新 2 天内过期的应用 |
| `selfsign://refresh?all=1` | 刷新全部 |
| `selfsign://refresh?bundle=com.example.app` | 刷新指定 Bundle ID |
| `selfsign://status` | 查询当前状态 |

支持 `x-success` / `x-error` / `x-cancel` 回调。

## 已知约束

- 最低 iOS 26.0（`LSMinimumSystemVersion` / `IPHONEOS_DEPLOYMENT_TARGET = 26.0`）。
- 免费 Apple ID：最多 3 个 App、7 天签名、每周约 10 次签名额度。
- 内置隧道使用 `packet-tunnel-provider` entitlement，需有效签名配置（ad-hoc 本地安装可用）。
- Anisette 依赖第三方 v3 服务；2026-10 后请用 windows-ADI 实现的服务器（设置里可填）。
- CI 的 ad-hoc IPA 每 7 天需重签（证书限制）。

## License

本项目代码用于个人学习与自签名研究。第三方依赖遵循各自许可证（MIT / GPL）。
