# 首个 macOS 工程

## 决定与依据

在多轮本机实验中，整段自动框选难以稳定表达用户意图；目前采用鼠标中心词与实时选区两条路径。已验证的本地实现依赖 macOS 的 ScreenCaptureKit、Vision、Accessibility 和 Translation，因此首个正式工程选用 Swift、AppKit/SwiftUI 与 macOS 15+，暂无第三方依赖。`tmp/scripts/word_magnifier_probe.swift` 是迁移时的实验基线；正式行为以 `Sources/EasyLens/` 为准。

## 源码边界

| 文件 | 职责 |
| --- | --- |
| `SelectionReader.swift` | 从目标应用读取实时选区及指针命中几何。 |
| `FocusOCR.swift`、`FocusText.swift` | Vision OCR、焦点词定位、英文判断、上下文与结果推导。 |
| `LocalTranslation.swift` | Translation 框架的单词与选区翻译桥接。 |
| `TranslationLanguageSetup.swift` | 英中资源就绪检查、首次使用引导、系统下载请求。 |
| `EyeLensView.swift` | 透明眼睛和识别成功状态的绘制。 |
| `EasyLensAppDelegate.swift` | 菜单栏、快捷键、屏幕捕获、异步调度与结果展示。 |
| `EasyLensMain.swift`、`DiagnosticTranslation.swift` | 应用入口与 Debug 诊断命令。 |

`Package.swift` 构建可执行文件，`scripts/build-app.sh` 将其与 `Resources/Info.plist` 组装成 `build/EasyLens.app`，然后对整包签名与校验。Bundle ID 为 `ai.nangua.EasyLens`。本机首次运行 `scripts/setup-local-signing.sh` 会在登录钥匙串创建仅供开发的固定签名身份；此后构建脚本自动使用它，也支持通过 `EASYLENS_CODESIGN_IDENTITY` 显式指定其他身份。未设置时回退到临时签名并给出警告。固定签名让源码更新后的代码身份保持稳定，避免辅助功能等系统授权因代码哈希变化而失效。`LSUIElement=true` 加上 AppKit accessory 激活策略，使应用只在菜单栏驻留，不显示 Dock 图标。

## 首次使用与权限

启动时查询英语到简体中文的系统翻译语言状态。未安装时打开 EasyLens 说明窗口；用户点击「下载语言」后调用 `TranslationSession.prepareTranslation()`，macOS 显示下载确认窗口。EasyLens 定期复查，资源就绪后恢复翻译；用户可从菜单栏重新打开说明。下载中或不可用时不会发起翻译请求。系统资源由 macOS 管理，应用不自行下载语言包。

屏幕画面由 ScreenCaptureKit 读取，选区辅助使用 Accessibility。首次唤醒时若录屏未授权，EasyLens 先说明用途并提供系统授权入口；权限就绪前不启动捕获，避免反复触发原生权限弹窗。若 macOS 的录屏应用列表没有 EasyLens，可以点击列表底部“＋”，在文件选择窗口用 ⇧⌘G 输入引导窗口展示的 `.app` 完整路径并添加；系统可能要求退出并重新打开应用。辅助功能未授权时另行说明完整选区翻译的依赖。菜单栏持续显示两项授权状态。读取选区时记录最近激活的外部应用，避免权限说明窗口或菜单栏短暂激活 EasyLens 时把自身误作目标。仅辅助功能权限不足时仍可单词翻译。应用不保存截图、不发送云端翻译请求。

## 构建与检查

```sh
sh scripts/setup-local-signing.sh
swift test
sh scripts/build-app.sh
sh scripts/run-app.sh --show-on-launch
EASYLENS_BUILD_CONFIGURATION=release sh scripts/build-app.sh
```

迁移检查已覆盖：Debug/Release 编译、英文与非英文门控、过期选区不覆盖当前焦点、相对时间表达、`.app` 的 `Info.plist`、菜单栏 accessory 激活策略、实际屏幕捕获和本地英译中。缺少语言资源的窗口可在 Debug 构建中通过 `--preview-language-setup` 预览；本机已有资源，因此未实测真实首次下载与安装完成时序。

当前仍是本地开发工程。本地自签名证书只用于保持开发机上的代码身份，不能用于正式分发或公证。从旧的临时签名切换后，已有的授权记录可能对应旧代码身份；可分别运行 `tccutil reset Accessibility ai.nangua.EasyLens` 与 `tccutil reset ScreenCapture ai.nangua.EasyLens` 清除旧记录，再用新构建授权一次。分发前需要正式签名与公证、安装与升级机制，以及在不同 macOS 版本和目标应用上的权限与选区回归测试。

## 系统接口依据

- [Apple：LanguageAvailability.Status](https://developer.apple.com/documentation/translation/languageavailability/status)：区分已安装、可下载与不支持。
- [Apple：TranslationSession.prepareTranslation()](https://developer.apple.com/documentation/translation/translationsession/preparetranslation%28%29)：请求系统准备并下载语言资源。
- [Apple：LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)：菜单栏应用不出现在 Dock。
- [Apple：TN3127 Code Signing Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)：解释代码身份与 TCC 授权的关系，以及临时签名的版本绑定。
- [Apple：CGPreflightScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess%28%29)：检查当前录屏授权状态。
