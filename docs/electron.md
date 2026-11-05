# Electron 工程

## 决定与边界

首个已验证原型依赖 macOS 的 ScreenCaptureKit、Vision、Accessibility 和 Translation。为了让同一交互能在本机 Linux 上构建、运行和继续迭代，正式入口迁移到 Electron。Linux 没有上述系统框架，因此实现按能力选择替代：

| 能力 | Electron 实现 | 已知差距 |
| --- | --- | --- |
| 托盘/菜单栏 | `Tray` + `skipTaskbar`，不创建主窗口 | Linux 桌面可能需要 AppIndicator 扩展才显示托盘。 |
| 全局快捷键 | `globalShortcut` 注册 `Control+Alt+L`；显示时临时注册 `Escape` | 快捷键被其他应用占用时注册失败，日志会给出 `ERROR wake hotkey unavailable`。 |
| 跟随鼠标的透明眼睛 | 190×114 透明无边框窗口，Canvas 绘制眼睛与红色呼吸灯 | 没有原生毛玻璃，使用半透明填充和中心挖空近似。 |
| 屏幕取像 | `desktopCapturer` 截取光标所在显示器，按 DIP/缩放裁剪约 900×240 | Wayland 依赖 PipeWire/portal；黑屏时优先用 X11。 |
| 取像时排除自身 | 截屏前短暂隐藏眼睛与翻译卡 | 会在静止扫描时造成很短的闪烁；重扫间隔提高到 2 秒。 |
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

1. 主进程每 16ms 读取鼠标位置，移动超过 3px 就更新眼睛位置、递增 generation、清空等待态。
2. 鼠标停稳 100ms 后，隐藏眼睛和翻译卡，用 `desktopCapturer` 截取光标附近 900×240（DIP）区域，然后立即恢复眼睛。
3. Tesseract 识别英文词框；`findFocus` 用中心距离选择词，并组合相邻行作为上下文。
4. 同时读取 PRIMARY/剪贴板 hint。若 hint 通过英文门控且包含焦点词，优先走完整选区，否则走单词。
5. 本地来源立即查词；DeepSeek 在 180ms 后显示「正在转译」卡。结果按 generation/requestId 校验，过期结果丢弃。
6. 翻译成功或失败都会更新眼睛的黄色状态；移动、目标变化和设置变更会清缓存并使旧请求失效。

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

- `npm test`：28 个测试通过（英文门控、选区边界、格式保留、DeepSeek 请求体、密钥权限、OCR 几何）。
- `npm run test:ocr`：输出 `OCR_SELF_TEST_OK`。
- `npm run smoke`：输出 `EASYLENS_READY`、`LENS_SHOWN`、`SMOKE_TEST_OK`。
- `npm run build`：生成 `dist/linux-unpacked/easylens`，打包后的二进制同样通过 smoke。
- 在 Xvfb + xfce4-terminal 中把固定焦点放在白色终端文本上，实际走通 `desktopCapturer → Tesseract → findFocus → 本地词典`，识别到 `world` 并显示译文；日志为 `FOCUS_TRANSLATION resolved=yes basis=本地词典`。
- 在同一环境用鼠标选中整行英文后启动，走通 Electron `clipboard` 的 PRIMARY 读取：`SELECTION_HINT source=primary length=57`，随后 `SELECTION_TRANSLATION resolved=yes provider=local fallback=true`。这验证了选区优先和本地逐词回退，不代表任意应用的高亮几何都能被确认。

未验证：Wayland 实际捕获、GNOME/KDE 托盘、真实用户 DeepSeek Key、复杂网页选区、不同字体/缩放的 OCR 准确率、Windows/macOS Electron 构建。

## 调试入口

- `--fixed-point X Y`：固定焦点，不依赖真实鼠标，便于无头验证。
- `--show-on-launch`：启动后直接显示眼睛。
- `--smoke-test`：启动、显示、展示示例卡，2.6 秒后退出。
- `EASYLENS_DEBUG_CAPTURE=1`：把最近一帧写到系统临时目录 `easylens-capture.png`（仅诊断，不在正常路径保存截图）。
- `EASYLENS_DEBUG_OCR=1`：输出 OCR 识别词。
- `EASYLENS_ENABLE_GPU=1`：Linux 上保留硬件加速（默认关闭以提高透明窗口兼容性）。

## 词库与第三方数据

`electron/data/en-zh.json` 是从 MIT 许可的 ECDICT npm 包（`ecdict`）中裁剪的常用词条，仅保留简短中文释义；版权与许可证见 `electron/data/LICENSE-data.txt`，数据来源说明见 `electron/data/NOTICE.md`。Tesseract 英文训练数据来自 `@tesseract.js-data/eng`。应用不把词库或密钥写入用户目录。
