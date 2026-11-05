# 工程结构与验证

## 正式入口：Electron

首个已验证原型依赖 macOS 的 ScreenCaptureKit、Vision、Accessibility 和 Translation。为了让同一交互能在 Linux 上构建、运行和继续迭代，正式入口迁移到 Electron；Linux 没有上述系统框架，因此按能力选择替代实现。完整的架构、数据流和差距表见 [electron.md](electron.md)。

| 文件 | 职责 |
| --- | --- |
| `electron/main.js` | 应用生命周期、托盘、透明窗口、全局快捷键、鼠标循环、截屏、异步翻译调度与缓存。 |
| `electron/preload.js` | `contextBridge` 暴露的最小 IPC API。 |
| `electron/app/focus-text.js` | 从 Swift 迁移的纯文本逻辑：英文门控、选区规范化、边界投影、焦点校验。 |
| `electron/app/ocr.js` | Tesseract 生命周期、词框提取、按中心点选词与上下文句子。 |
| `electron/app/local-dictionary.js` | 内置 ECDICT 子集加载、词形还原和释义清理。 |
| `electron/app/local-translator.js` | 离线单词/选区回退翻译。 |
| `electron/app/deepseek.js` | DeepSeek Chat Completions 请求、响应解析和错误信息。 |
| `electron/app/settings-store.js` | `~/.easylens` 设置与 API Key 存储（目录 `0700`、文件 `0600`）。 |
| `electron/renderer/lens.*` | 透明眼睛 Canvas、识别/成功状态和取像抑制。 |
| `electron/renderer/card.*` | 译文卡、等待卡、动态尺寸与位置反馈。 |
| `electron/renderer/settings.*` | 翻译来源、HTTPS 地址、模型、密钥和连接测试界面。 |
| `electron/data/en-zh.json` | 约 2.6 万条常用英汉词条，离线默认翻译来源；许可见 `electron/data/NOTICE.md`。 |

`package.json` 定义 Electron 入口、测试、构建和冒烟脚本。`electron-builder --linux dir` 生成 `dist/linux-unpacked/`；为兼容 Tesseract 的语言数据与工作脚本，打包时关闭 asar。默认构建目标不依赖 AppImage 工具链。

### 构建与检查

需要 Node.js 20+、npm，以及 Electron 在 Linux 上常用的 GTK/NSS/GBM 运行库。无桌面环境时使用 Xvfb。

```sh
npm install
npm test
npm run test:ocr
npm run build
npm run smoke
./dist/linux-unpacked/easylens --show-on-launch
```

本机已验证 `npm test` 的 28 个测试、`npm run test:ocr`（`OCR_SELF_TEST_OK`）、真实 Electron 冒烟（`EASYLENS_READY`、`LENS_SHOWN`、`SMOKE_TEST_OK`）和 `npm run build`；打包后的二进制同样通过冒烟。另在 Xvfb + xfce4-terminal 中固定焦点，走通 `desktopCapturer → Tesseract → findFocus → 本地词典`，识别到 `world` 并显示译文；选中整行英文后也走通 PRIMARY 选区读取和本地回退翻译（`SELECTION_HINT source=primary`、`SELECTION_TRANSLATION resolved=yes`）。

未验证：Wayland 实际捕获、GNOME/KDE 托盘、真实用户 DeepSeek Key、复杂网页选区、不同字体/缩放的 OCR 准确率，以及 Windows/macOS 的 Electron 构建。细节和调试参数见 [electron.md](electron.md)。

## 归档：macOS Swift 原型

以下内容保留原型的选型、权限、构建和验证记录，仅作为 macOS 行为参考。原工程需要 macOS 15+ 与 Xcode 16+，不再是默认构建入口，也不被 Electron 运行路径依赖。

### 决定与依据

在多轮本机实验中，整段自动框选难以稳定表达用户意图；原型采用鼠标中心词与实时选区两条路径。已验证的本地实现依赖 macOS 的 ScreenCaptureKit、Vision、Accessibility 和 Translation，因此首个正式工程选用 Swift、AppKit/SwiftUI 与 macOS 15+，暂无第三方依赖。`tmp/scripts/word_magnifier_probe.swift` 是迁移时的实验基线；原型行为以 `Sources/EasyLens/` 为准。

### 源码边界

| 文件 | 职责 |
| --- | --- |
| `SelectionReader.swift` | 从目标应用读取实时选区及指针命中几何。 |
| `FocusOCR.swift`、`FocusText.swift` | Vision OCR、焦点词定位、英文判断、上下文与结果推导。 |
| `LocalTranslation.swift` | Translation 框架的单词与选区翻译桥接。 |
| `DeepSeekTranslation.swift` | DeepSeek Chat Completions 请求及响应解析。 |
| `TranslationSettings.swift` | 翻译来源、接口地址、模型与 `~/.easylens` 密钥存储，以及设置窗口。 |
| `TranslationLanguageSetup.swift` | 英中资源就绪检查、首次使用引导、系统下载请求。 |
| `EyeLensView.swift` | 透明眼睛和识别成功状态的绘制。 |
| `EasyLensAppDelegate.swift` | 菜单栏、快捷键、屏幕捕获、异步调度与结果展示。 |
| `EasyLensMain.swift`、`DiagnosticTranslation.swift` | 应用入口与 Debug 诊断命令。 |

`Package.swift` 构建可执行文件，`scripts/build-app.sh` 将其与 `Resources/Info.plist` 组装成 `build/EasyLens.app`，然后对整包签名与校验。Bundle ID 为 `ai.nangua.EasyLens`。本机首次运行 `scripts/setup-local-signing.sh` 会在登录钥匙串创建仅供开发的固定签名身份；此后构建脚本自动使用它，也支持通过 `EASYLENS_CODESIGN_IDENTITY` 显式指定其他身份。未设置时回退到临时签名并给出警告。固定签名让源码更新后的代码身份保持稳定，避免辅助功能等系统授权因代码哈希变化而失效。`LSUIElement=true` 加上 AppKit accessory 激活策略，使原型只在菜单栏驻留，不显示 Dock 图标；进程启动时通过 `EasyLens.lock` 保持单实例运行，重新构建 `.app` 后需退出旧菜单栏进程再启动新构建。

### 首次使用与权限

使用本地翻译时查询英语到简体中文的系统翻译语言状态。未安装时打开 EasyLens 说明窗口；用户点击「下载语言」后调用 `TranslationSession.prepareTranslation()`，macOS 显示下载确认窗口。EasyLens 定期复查，资源就绪后恢复翻译；用户可从菜单栏重新打开说明。下载中或不可用时不会发起翻译请求。系统资源由 macOS 管理，原型不自行下载语言包。

屏幕画面由 ScreenCaptureKit 读取，选区辅助使用 Accessibility。首次唤醒时若录屏未授权，原型先说明用途并提供系统授权入口；权限就绪前不启动捕获，避免反复触发原生权限弹窗。若 macOS 的录屏应用列表没有 EasyLens，可以点击列表底部“＋”，在文件选择窗口用 ⇧⌘G 输入引导窗口展示的 `.app` 完整路径并添加；系统可能要求退出并重新打开应用。辅助功能未授权时另行说明完整选区翻译的依赖。菜单栏持续显示两项授权状态。读取选区时记录最近激活的外部应用，避免权限说明窗口或菜单栏短暂激活 EasyLens 时把自身误作目标。仅辅助功能权限不足时仍可单词翻译。原型不保存或发送截图。选择 DeepSeek 时，焦点词及句子上下文或完整选区会发送至所配置的 HTTPS 接口；切换来源会清除翻译缓存并使旧请求失效。API Key 保存在 `~/.easylens/deepseek-api-key`（目录 `0700`、文件 `0600`），避免无公证本地构建访问钥匙串时触发密码弹窗；非敏感设置存在 UserDefaults。

远端请求启动后，约 180 毫秒仍未返回才显示等待卡；缓存命中和快速响应直接显示译文。等待卡复用翻译浮窗，显示目标词或“完整选区”及轻微动态点，眼睛的黄色成功态只由实际译文触发。指针移动、目标变化、请求失效和错误会清除等待态；结果到达时先收起旧卡再展示译文。视觉选区短暂漏检时先复核，避免选区译文被单词译文瞬间覆盖。

### 构建与检查

以下命令只在 macOS 的原型工程中有效：

```sh
sh scripts/setup-local-signing.sh
swift test
sh scripts/build-app.sh
sh scripts/run-app.sh --show-on-launch
EASYLENS_BUILD_CONFIGURATION=release sh scripts/build-app.sh
```

迁移检查已覆盖：Debug/Release 编译、英文与非英文门控、过期选区不覆盖当前焦点、相对时间表达、`.app` 的 `Info.plist`、菜单栏 accessory 激活策略、实际屏幕捕获和本地英译中。DeepSeek 请求格式及焦点词、选区正文已用模拟接口核对；真实接口调用需用户在设置中输入自己的 API Key 后验证。缺少语言资源的窗口可在 Debug 构建中通过 `--preview-language-setup` 预览；本机已有资源，因此未实测真实首次下载与安装完成时序。

在 VS Code 打开的 Markdown 中，Vision 快速 OCR 曾把中文误读出 `/`，旧规则因此跳过整行，使同一行的英文词也无法定位；偶发单帧识别失败还会立即收起翻译卡。现仅遮蔽识别到的路径/文件名片段，保留相邻词，并在静止焦点下容忍一次空帧。已用该 README 的编辑器截图验证 `Renderer`、`lock` 可定位而路径本身不被选为词；固定焦点的运行检查连续命中并维持翻译卡。不同主题、字号与选区的表现仍需继续实测。

在 Chromium 内核浏览器（如 Tabbit、Chrome）中跨多个标题、段落或列表项划选时，`kAXSelectedTextAttribute` 与 `AXStringForTextMarkerRange` 会直接拼接各块级节点的文字而不插入换行符（如 `termsWe know`、`you.These`、`services• What`），且在仅根节点 `AXWebArea` 暴露完整选区、段落内含行内按钮/控件（如 `services (?)`）时，从页面顶部遍历与全串字面匹配会漏失块边界；本地 Translation 不同于云端大模型，拿到未分段字符串时会将标题与正文合译为单段。现由 `SelectionReader` 保留从鼠标命中叶子节点向上的完整祖先链，合成子节点几何命中与上层节点的完整选区，围绕命中节点做局部块遍历与相邻块尾首接缝投影（Boundary-Junction Projection），配合 `FocusText` 对无空格块接缝（标题与正文、句末标点与下段首词、行内项目符号及无空格间隔号列表，保留 `GitHub` 等大小写专有名词与外文人名间隔号）做正字法分段兜底；本地 Translation 按段发起批量请求，DeepSeek 提示词显式保留段落换行，选区卡片通过 `NSAttributedString` 配置行距与段距；同时将多段散文选区上限扩至 4000 字符、在密集 OCR 下围绕焦点词裁剪窗口，并在视觉高亮核对中结合外缘背景参照与当前行有色填充判定。已通过 Tabbit 实时框选、截图样本及单元测试验证；复杂表格、Canvas 及其他第三方应用的辅助功能树表现仍需继续实测。

原型仍是本地开发工程。本地自签名证书只用于保持开发机上的代码身份，不能用于正式分发或公证。从旧的临时签名切换后，已有的授权记录可能对应旧代码身份；可分别运行 `tccutil reset Accessibility ai.nangua.EasyLens` 与 `tccutil reset ScreenCapture ai.nangua.EasyLens` 清除旧记录，再用新构建授权一次。分发前需要正式签名与公证、安装与升级机制，以及在不同 macOS 版本和目标应用上的权限与选区回归测试。

### 系统接口依据

- [Apple：LanguageAvailability.Status](https://developer.apple.com/documentation/translation/languageavailability/status)：区分已安装、可下载与不支持。
- [Apple：TranslationSession.prepareTranslation()](https://developer.apple.com/documentation/translation/translationsession/preparetranslation%28%29)：请求系统准备并下载语言资源。
- [Apple：LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)：菜单栏应用不出现在 Dock。
- [Apple：TN3127 Code Signing Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)：解释代码身份与 TCC 授权的关系，以及临时签名的版本绑定。
- [Apple：CGPreflightScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess%28%29)：检查当前录屏授权状态。
- [DeepSeek：首次调用 API](https://api-docs.deepseek.com/zh-cn/)：OpenAI 兼容接口地址、鉴权、模型名和 Chat Completions 请求。
- [DeepSeek：思考模式](https://api-docs.deepseek.com/zh-cn/guides/thinking_mode/)：翻译请求关闭默认思考模式以减少延迟。
