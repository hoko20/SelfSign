# LiveContainer 集成说明（SelfSign 内置 · 全功能保留）

本目录是 [LiveContainer](https://github.com/LiveContainer/LiveContainer) 官方仓库的完整源码快照，**未经删减**，保留全部 10 个 target 与功能。原始 `README.md` 与 `LICENSE`（AGPL-3.0）均原样保留。

> An app launcher that runs iOS apps without actually installing them.
> 一个 App / 一个 App ID 运行无限个 App，绕开免费账号 3 App / 10 App ID 限制，支持多版本共存、容器隔离、JIT/JIT-less、Tweak 注入、多开、AltStore 源、插件支持。

## 与 SelfSign 的关系（已合并为单一 App）

- **一个 IPA，一个进程**：LiveContainer 的 `main.c` 引导 + `LiveContainerShared.framework` 运行时 + `LiveContainerSwiftUI.framework` 原生 UI，与 SelfSign 的 Rust 签名引擎和 SwiftUI 页面**编译进同一个 `SelfSign.app`**。
- 启动链：`main.c` → `LiveContainerMain()`（`LiveContainerShared.framework`）→ `dlopen(LiveContainerSwiftUI.framework)` → SwiftUI `LiveContainerSwiftUIApp.main()`。SelfSign 在 `init()` 中完成 Rust FFI 初始化并注入 `AppStore` / `ShortcutRouter` 环境。
- UI 合并：`LCTabView` 保留原有「源 / 应用 / Tweak / 设置」Tab，新增「签名」「配对」两个 Tab（`ios/SelfSign/Views/`），共享同一份 Aqua/Liquid Glass 外观。
- 所有二进制组件（TweakLoader / ZSign / TestJITLess / SideStoreSupport / OpenSSL / CydiaSubstrate / LiveProcess / ShareExtension / LaunchAppExtension / TunnelProv）作为**同一个 App 的内嵌框架与扩展**交付，不再是第二个 App。
- CI 只构建一个 target `SelfSign`，只产出一个 `SelfSign-adhoc.ipa`。

## 目录分类

| 目录 | 职责 |
|---|---|
| `LiveContainer/` | 主程序 C/ObjC 核心：`main.c`、MachO 工具、dyld 校验绕过、Tweak hooks、LivePlugIn 支持 |
| `LiveContainerSwiftUI/` | SwiftUI 界面层：`App/` `Models/` `Views/` `Utilities/` `MultitaskSupport/`，按功能再分 `Views/AppList`、`Views/Settings`、`Views/AppList/AppSettings` 等 |
| `LiveProcess/` | Guest App 运行的 app-extension 进程 |
| `ShareExtension/` | 系统分享扩展（导入 IPA / URL） |
| `LaunchAppExtension/` | ExtensionKit 启动扩展 |
| `TweakLoader/` | 动态库 tweak 加载器 |
| `litehook/` | 子模块：fishhook 风格的 MachO hook 实现（MIT） |
| `ZSign/` | 内置 IPA 重签引擎（C/C++） |
| `SideStoreSupport/` | SideStore 集成框架（XPC、AppIntents hooks） |
| `TestJITLess/` | JIT-less 签名验证样例 |
| `Resources/` | 资产、设置包、40+ 语言本地化（含 `zh_CN`/`zh_HK`/`zh_TW`） |
| `xcconfigs/` | 构建配置（App Group、Bundle ID、Team 后缀） |
| `Dependencies/` | 外部依赖（构建时下载 `OpenSSL.xcframework`） |
| `LiveContainer.xcodeproj/` | 官方 Xcode 工程 + 3 个共享 scheme |
| `.github/` | 官方构建脚本、AltStore 源配置 |

## 构建

官方要求 **Xcode 27 / iOS 26+ SDK**，先准备依赖再 archive：

```bash
sh .github/prepare_dependencies.sh        # 下载 OpenSSL.xcframework
xcodebuild -project LiveContainer.xcodeproj -scheme LiveContainer \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO clean archive
```

## 许可与归属

- 主项目：[GNU AGPL-3.0](./LICENSE) — 完整许可文本随源码保留。
- litehook / fishhook：MIT（见各自子目录 LICENSE）。
- 本项目未修改其源码逻辑；若修改，按 AGPL-3.0 要求需开源变更。
