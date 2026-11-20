# Electron 工程

## 决定与边界

首个已验证原型依赖 macOS 的 ScreenCaptureKit、Vision、Accessibility 和 Translation。为了让同一交互能在本机 Linux 上构建、运行和继续迭代，正式入口迁移到 Electron。Linux 没有上述系统框架，因此实现按能力选择替代：

| 能力 | Electron 实现 | 已知差距 |
| --- | --- | --- |
| 托盘/菜单栏 | `Tray` + `skipTaskbar`，不创建主窗口 | Linux 桌面可能需要 AppIndicator 扩展才显示托盘。 |
| 全局快捷键 | `globalShortcut` 注册 `Control+Alt+L`；显示时临时注册 `Escape` | 快捷键被其他应用占用时注册失败，日志会给出 `ERROR wake hotkey unavailable`。 |
| 跟随鼠标的透明眼睛 | 190×114 透明无边框窗口，Canvas 绘制眼睛与红色呼吸灯 | 没有原生毛玻璃，使用半透明填充和中心挖空近似。 |
| 屏幕取像 | `desktopCapturer` 截取光标所在显示器，按 DIP/缩放裁剪约 900×240 | Wayland 依赖 PipeWire/portal；黑屏时优先用 X11。 |
| 取像时排除自身 | Linux 短暂隐藏真窗口；macOS/Windows 只把渲染层设为透明并跳过绘制，不隐藏窗口 | Linux 的隐藏路径会在静止扫描时造成很短的闪烁；重扫间隔提高到 2 秒。macOS/Windows 不再频繁重建窗口层级。 |
| OCR | Tesseract.js + `@tesseract.js-data/eng`，随包离线语言数据 | 只识别英文；精度和版面分析弱于 Vision。 |
| 英文门控 | `focus-text.js` 的 `eligibleEnglishText`、路径/代码过滤和拉丁字母判断 | 不使用系统语言识别器，混排文本的判定更保守。 |
| 鼠标中心词 | Tesseract 词框 + 归一化距离，选择中心附近最近的合法英文词 | 词框不是 Vision 的逐字符框，斜体/多列场景可能偏移。 |
| 完整选区 | Linux PRIMARY（Electron `clipboard` 的 `selection`，回退 `wl-paste`/`xclip`/`xsel`）优先，其次近期剪贴板；必须通过英文门控且包含当前焦点词 | 没有 Accessibility 的选区几何，因此不能确认指针真正落在高亮区域内，存在误判可能；不可用时退回单词。 |
| 单词翻译 | 内置 ECDICT 子集 + 词形还原；相对时间表达本地直译 | 词典覆盖率有限，未收录词不显示译文。 |
| 选区翻译 | 本地时按短语/逐词释义；可选 DeepSeek 整段翻译 | 本地逐词结果不保证语法通顺；需要高质量译文时配置 DeepSeek。 |
| DeepSeek | 主进程 `fetch` 调用 HTTPS `/chat/completions`，关闭 thinking，30 秒超时 | 需要用户自己的 API Key；请求只发待译文字，不发截图。 |

## 源码边界

| 文件 | 职责 |
| --- | --- |
| `electron/main.js` | 应用生命周期、托盘、窗口、快捷键、鼠标循环、截屏、异步翻译调度与缓存。 |
| `electron/preload.js` | `contextBridge` 暴露的最小 IPC API。 |
| `electron/app/focus-text.js` | 从 Swift `FocusText.swift` / `SelectionReader.swift` 迁移的纯文本逻辑：英文门控、选区规范化、边界投影、焦点校验。 |
| `electron/app/focus-session.js` | 纯焦点/请求生命周期：微移与大位移判定、截屏去重、OCR miss 阈值、成功结果缓存优先与错误文案。 |
| `electron/app/ocr.js` | Tesseract 生命周期、词框提取、按中心点选词与上下文句子。 |
| `electron/app/local-dictionary.js` | 内置词库加载、词形还原、简短释义清理。 |
| `electron/app/local-translator.js` | 离线单词/选区回退翻译。 |
| `electron/app/deepseek.js` | DeepSeek 请求、响应解析和错误信息。 |
| `electron/app/settings-store.js` | `~/.easylens` 设置与 API Key 存储（目录 `0700`、文件 `0600`）。 |
| `electron/renderer/lens.*` | 透明眼睛 Canvas 与状态/抑制消息。 |
| `electron/renderer/card.*` | 翻译卡、加载卡、动态尺寸与位置反馈。 |
| `electron/renderer/settings.*` | 翻译来源、HTTPS 地址、模型、密钥和连接测试界面。 |
| `electron/data/en-zh.json` | 约 2.6 万条常用英汉词条，离线默认翻译来源。 |

## 一次焦点扫描的数据流

1. 主进程每 16ms 读取鼠标位置并同步眼睛位置。移动 3–15px 只触发重新观察，不递增 generation、不清空等待态；达到 16px 才视为明显换位并清理当前焦点。
2. 鼠标停稳 100ms 后，Linux 隐藏眼睛与翻译卡再截取光标附近 900×240（DIP）区域，随后 `showInactive()`；macOS/Windows 只用 `lens:suppress` 让透明 Canvas 停止绘制，再截屏，避免 WindowServer 反复重建窗口层级导致闪烁。同一位置/锚点的 400ms 内重复截屏会被跳过。
3. Tesseract 识别英文词框；`findFocus` 用中心距离选择词，并组合相邻行作为上下文。
4. 同时读取 PRIMARY/剪贴板 hint。若 hint 通过英文门控且包含焦点词，优先走完整选区，否则走单词。
5. 本地来源立即查词；DeepSeek 在 180ms 后显示「正在转译」卡。成功结果先写入缓存，再用「窗口可见 + pending key/选区文本 + 当前锚点」判断是否展示；微颤造成的 generation 变化不再丢弃在途请求。OCR 连续 miss 时，有在途远端请求会容忍更多次确认。
6. 翻译成功或失败都会更新眼睛的黄色状态；失败会显示短错误卡（超时、连接失败、HTTP 状态、未配置密钥等），不会静默隐藏。明显移动、选区变化、主动隐藏和设置变更会清缓存并使旧请求失效。
7. 显示、托盘恢复和截屏结束后发送 `lens:suppress false` + `lens:resume`，让渲染层立刻重绘完整眼睛。`toggleLens()` 会在 `state.visible` 为真但窗口实际不可见（例如 Linux 截屏隐藏期间）时优先恢复显示。

## 构建与验证

```sh
npm install
npm test
npm run test:ocr
npm run build
npm run smoke
```

`scripts/ocr-self-test.js` 使用 `electron/assets/ocr-sample.png` 验证随包语言数据、词框提取和焦点几何，不启动 Electron。`scripts/smoke-test.sh` 使用 Xvfb 启动真实 Electron 进程，检查托盘、眼睛窗口、翻译卡和 `EASYLENS_READY` 日志。

本机已验证：

- `npm test`：39 个测试通过（英文门控、选区边界、格式保留、DeepSeek 请求体、密钥权限、OCR 几何、微移/换词请求生命周期、错误文案与截屏去重）。
- `npm run test:ocr`：输出 `OCR_SELF_TEST_OK`。
- `npm run smoke`：输出 `EASYLENS_READY`、`LENS_SHOWN`、`SMOKE_TEST_OK`。
- `npm run build`：生成 `dist/linux-unpacked/easylens`，打包后的二进制同样通过 smoke。
- 在 Xvfb + xfce4-terminal 中把固定焦点放在白色终端文本上，实际走通 `desktopCapturer → Tesseract → findFocus → 本地词典`，识别到 `world` 并显示译文；日志为 `FOCUS_TRANSLATION resolved=yes basis=本地词典`。
- 在同一环境用鼠标选中整行英文后启动，走通 Electron `clipboard` 的 PRIMARY 读取：`SELECTION_HINT source=primary length=57`，随后 `SELECTION_TRANSLATION resolved=yes provider=local fallback=true`。这验证了选区优先和本地逐词回退，不代表任意应用的高亮几何都能被确认。

未验证：Wayland 实际捕获、GNOME/KDE 托盘、复杂网页/多字体/缩放的 OCR 准确率、Windows 与 macOS Apple Silicon（arm64）实机构建，以及 `release.yml` 通用二进制在 GitHub Actions 上的新 tag 运行结果。

## macOS 实机排查与经验记录（macOS 15.7.7 x86_64）

以下为 2026-11-19 在 macOS 15.7.7（Intel x86_64）上对 `/Applications/EasyLens.app` 的实机排障事实与已落地修复，供后续迭代与云端协作参考：

### 1. ad-hoc 签名与 TCC `CDHash` 冲突（开关亮着但始终提示未授权）

- **实证事实**：`tccd` 系统日志明确报错 `Failed to match existing code requirement for subject ai.nangua.EasyLens and service kTCCServiceScreenCapture (cdhash H"...")`；在系统设置里反复开关蓝条只改 `auth_value`，**不会更新已绑定的 `cdhash`**。同时，直接修改 `.app` 内文件会导致 `codesign --verify --deep --strict` 报 `nested code is modified or invalid`，嵌套无签名二进制会被 `tccd` 标记为 `<ID of InvalidCode>`。
- **处理方法**：修改 `.app` 后必须对嵌套助手（`electron/bin/macos-selection-reader`）和整个 `.app` 执行 `codesign --force --deep --sign -`，并确认 `codesign --verify --deep --strict` 返回 `valid on disk`。升级或重签 ad-hoc 包后，必须先在系统设置中点 **`-`** 移除旧条目（或执行 `tccutil reset ScreenCapture ai.nangua.EasyLens` 与 `tccutil reset Accessibility ai.nangua.EasyLens`），再点 **`+`** 重新添加 `/Applications/EasyLens.app`。
- **已知边界**：只要继续使用 `"identity": null`（ad-hoc），每次发版/重签都会更换 `CDHash`；如需升级不掉权限，需切换到固定自签名证书或 Developer ID 证书。

### 2. `closable: false` 阻断 macOS 退出并注销全部全局快捷键

- **实证事实**：`lensWindow` 与 `cardWindow` 创建时带有 `closable: false`。触发退出（如系统设置授权后点击「退出并重新打开」、菜单栏「退出 EasyLens」或 `⌘Q`）时，`before-quit` 先执行了 `globalShortcut.unregisterAll()`，随后 macOS 拒绝关闭不可关闭窗口并中止退出，导致进程残留且 `⌃⌥L` 与 `Esc` 全部失效。
- **已落地修复**：`before-quit` 中显式对 `lensWindow`、`cardWindow`、`settingsWindow` 调用 `.destroy()` 确保退出完成；将 `unregisterEscape()` 与 `globalShortcut.unregisterAll()` 移至 `will-quit`；macOS 仅注册一次 `Control+Alt+L`。

### 3. 截屏失败时 800ms 重试退避被每 16ms `tick()` 清零

- **实证事实**：未授权录屏时，`scheduleCaptureRetry` 写入的 `nextInspectionAt = now + 0.8` 会在 16ms 后的下一次 `tick()` 中被 `movement !== 'stationary'` 清零，导致日志以 60fps 狂刷 `CAPTURE_ERROR` 并拉高 CPU。
- **已落地修复**：仅在鼠标真实物理移动（`frameDistance >= 1.5`）时清零 `nextInspectionAt`；实测未授权重试间隔已稳定为 ~800ms。

### 4. macOS 划选读取超时与 14.79 秒 AX DOM 重复遍历

- **实证事实**：在已确认辅助功能授权通过（`tccd` 返回 `authValue=2`）的前提下，在浏览器（多屏坐标 `--point 2160 726`）划选单段标题 `"What's covered in these terms"` 仍高概率退回单词翻译。直接计时执行 `macos-selection-reader --point 2160 726` 耗时 **14.79 秒**（`2.98s user + 1.30s sys`），被 Electron 子进程超时强杀（日志 `SELECTION_READER_FAILED`）。
- **根因**：`Sources/EasyLens/SelectionReader.swift` 的 `structuredSelectionText()` 在单段选区未命中多段时未写入缓存，导致 `inspectAncestors` 遍历祖先链时重复对整棵网页 AX DOM 树做全量扫描；此外旧版 Electron 超时过短（`250ms` / `350ms`）、未对 Chromium/Electron 设置 `AXEnhancedUserInterface = true`、只查询 `frontmostApplication`、托盘菜单未提示辅助功能授权状态，且 CI 仅编译单架构 `macos-selection-reader`。
- **已落地修复**：
  - `SelectionReader.swift` 增加 `AXStaticText` 单节点 0ms 快路径、180ms 时间上限、最多遍历 3 个容器（`maxNodes: 300`）以及未命中缓存，同坐标实测耗时从 14.79 秒降至 `< 0.7s`（CPU 约 30ms），实机划选整句翻译验收通过。
  - `SelectionReader.swift` 优先通过系统级光标命中获取光标所在窗口 PID（支持非前台窗口）并设置 `AXEnhancedUserInterface = true` 与 `0.5s` AX 超时。
  - `electron/main.js` 将 `macos-selection-reader` 超时放宽至 `1500ms`，并在 macOS 托盘菜单增加「辅助功能（划选翻译）」授权状态与一键跳转。
  - `.github/workflows/release.yml` 改为用 `swiftc` + `lipo` 编译 `arm64 + x86_64` 通用二进制并 ad-hoc 签名。

### 5. 托盘图标点击交互

- 移除 `tray.on('click', toggleLens)`，点击系统托盘图标仅展开下拉菜单，眼睛的显示/隐藏只通过下拉菜单项与快捷键（`⌃⌥L` / `Esc`）触发。

## 调试入口

- `--fixed-point X Y`：固定焦点，不依赖真实鼠标，便于无头验证。
- `--show-on-launch`：启动后直接显示眼睛。
- `--smoke-test`：启动、显示、展示示例卡，2.6 秒后退出。
- `EASYLENS_DEBUG_CAPTURE=1`：把最近一帧写到系统临时目录 `easylens-capture.png`（仅诊断，不在正常路径保存截图）。
- `EASYLENS_DEBUG_OCR=1`：输出 OCR 识别词。
- `EASYLENS_ENABLE_GPU=1`：Linux 上保留硬件加速（默认关闭以提高透明窗口兼容性）。

## 词库与第三方数据

`electron/data/en-zh.json` 是从 MIT 许可的 ECDICT npm 包（`ecdict`）中裁剪的常用词条，仅保留简短中文释义；版权与许可证见 `electron/data/LICENSE-data.txt`，数据来源说明见 `electron/data/NOTICE.md`。Tesseract 英文训练数据来自 `@tesseract.js-data/eng`。应用不把词库或密钥写入用户目录。
