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

`Package.swift` 构建可执行文件，`scripts/build-app.sh` 将其与 `Resources/Info.plist` 组装成 `build/EasyLens.app`，然后对整包进行本地临时签名与校验。Bundle ID 和签名标识均为 `ai.nangua.EasyLens`。`LSUIElement=true` 加上 AppKit accessory 激活策略，使应用只在菜单栏驻留，不显示 Dock 图标。

## 首次使用与权限

启动时查询英语到简体中文的系统翻译语言状态。未安装时打开 EasyLens 说明窗口；用户点击「下载语言」后调用 `TranslationSession.prepareTranslation()`，macOS 显示下载确认窗口。EasyLens 定期复查，资源就绪后恢复翻译；用户可从菜单栏重新打开说明。下载中或不可用时不会发起翻译请求。系统资源由 macOS 管理，应用不自行下载语言包。

屏幕画面由 ScreenCaptureKit 读取，选区辅助使用 Accessibility。首次授权依赖 macOS 的权限提示或系统设置；当前尚无独立的权限向导。应用不保存截图、不发送云端翻译请求。

## 构建与检查

```sh
swift test
sh scripts/build-app.sh
sh scripts/run-app.sh --show-on-launch
EASYLENS_BUILD_CONFIGURATION=release sh scripts/build-app.sh
```

迁移检查已覆盖：Debug/Release 编译、英文与非英文门控、过期选区不覆盖当前焦点、相对时间表达、`.app` 的 `Info.plist`、菜单栏 accessory 激活策略、实际屏幕捕获和本地英译中。缺少语言资源的窗口可在 Debug 构建中通过 `--preview-language-setup` 预览；本机已有资源，因此未实测真实首次下载与安装完成时序。

当前仍是本地开发工程。临时签名不能代替正式开发者签名，重新构建后系统权限可能需要重新授权。分发前需要正式签名与公证、安装与升级机制、完整的权限向导，以及在不同 macOS 版本和目标应用上的回归测试。

## 系统接口依据

- [Apple：LanguageAvailability.Status](https://developer.apple.com/documentation/translation/languageavailability/status)：区分已安装、可下载与不支持。
- [Apple：TranslationSession.prepareTranslation()](https://developer.apple.com/documentation/translation/translationsession/preparetranslation%28%29)：请求系统准备并下载语言资源。
- [Apple：LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)：菜单栏应用不出现在 Dock。
