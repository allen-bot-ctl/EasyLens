# EasyLens

EasyLens 是菜单栏/托盘中的英译中应用。按 **Ctrl+Alt+L**（macOS 语义为 ⌃⌥L）唤出跟随鼠标的透明眼睛，停留在英文单词上可查看中文；按 **Esc** 隐藏眼睛。非英文内容不进入翻译流程。鼠标中心位于已选文字上时，优先翻译完整选区（Linux 使用 PRIMARY/剪贴板回退，见下文）。

当前正式可运行入口已经迁移到 **Electron**，可在 Linux 上安装、启动和构建；原 macOS 15+ Swift/ScreenCaptureKit/Vision/Accessibility/Translation 工程保留在 `Sources/EasyLens/` 作为行为参考，不再作为默认构建入口。

## 快速开始（Electron）

需要 Node.js 20+ 与 npm。Linux 桌面还需要 Electron 常见的 GTK/NSS/GBM 运行库；无桌面环境可用 `xvfb-run` 做启动检查。

```sh
npm install
npm run start:show     # 启动并显示眼睛；不带 --show-on-launch 时只驻留托盘
npm start              # 只驻留托盘，Ctrl+Alt+L 唤出
npm test               # 纯文本逻辑、翻译和密钥存储测试
npm run test:ocr       # 用内置样张验证 Tesseract OCR
npm run build          # electron-builder --linux dir
npm run smoke          # 在 Xvfb 中启动真实 Electron 进程做启动检查
```

构建产物为 `dist/linux-unpacked/`，可直接运行：

```sh
./dist/linux-unpacked/easylens --show-on-launch
```

`npm run dist` 会尝试生成 AppImage；本仓库的默认验证目标是 `dir`，避免依赖额外的打包工具链。

## 使用

- **Ctrl+Alt+L**：显示或隐藏眼睛。**Esc**：隐藏。
- 鼠标移动时眼睛跟随；停稳约 100ms 后读取鼠标附近画面并识别英文。
- 单词优先使用随包内置的英汉词典（ECDICT 子集，离线）。找不到时不会编造译文。
- 默认不保存截图；只有设置 `EASYLENS_DEBUG_CAPTURE=1` 时才会把最近一帧写到系统临时目录用于诊断。
- 托盘菜单的「设置…」可选择本地词典或 DeepSeek，填写 HTTPS 接口地址、模型和 API Key，并可测试连接。
- DeepSeek API Key 保存在 `~/.easylens/deepseek-api-key`（目录 `0700`、文件 `0600`）；非敏感设置保存在 `~/.easylens/settings.json`。密钥不会写入仓库。
- 选择 DeepSeek 时，待译文字会发送到配置的 HTTPS 接口；截图不会上传。

## Linux / Electron 上的能力差距

| macOS 原生能力 | Electron/Linux 现状 |
| --- | --- |
| ScreenCaptureKit 取像并排除自身窗口 | Electron `desktopCapturer`；拍照前短暂隐藏眼睛窗口，避免遮住目标文字。 |
| Vision OCR | Tesseract.js + 随包 `eng` 语言数据；只识别英文，复杂字体、低分辨率和暗色界面的准确率低于 Vision。 |
| Accessibility 读取任意应用选区与命中几何 | 读取 X11/Wayland PRIMARY（Electron `clipboard` 的 `selection` 类型，必要时回退到 `wl-paste`、`xclip`、`xsel`）或近期剪贴板提示；没有精确 AX 命中几何，可能把陈旧选区误判为当前选区。 |
| macOS Translation 本地英译中 | 无系统翻译框架。单词使用内置词典；长选区只能逐词释义，质量明显低于真正的机器翻译；需要完整译文时请配置 DeepSeek。 |
| 菜单栏 `LSUIElement` | 托盘应用 + `skipTaskbar`；主要 Linux 桌面可能需要 AppIndicator 扩展才能显示托盘图标。 |
| 录屏/辅助功能 TCC 授权流程 | 不再需要 TCC；Wayland 下屏幕捕获由 PipeWire/portal 管理，首次可能弹系统授权。若捕获为黑屏，优先在 X11 会话运行。 |
| 原生毛玻璃眼睛 | Canvas 绘制近似透明眼睛，中心保持透明；不依赖原生材质。 |

## 原 macOS 工程（参考）

`Sources/EasyLens/`、`Package.swift`、`Resources/Info.plist` 与 `scripts/build-app.sh` 等仍保留，需要 macOS 15+、Xcode 16+ 才能构建。原行为说明和权限细节见 [docs/engineering.md](docs/engineering.md) 的归档部分。

## 仓库入口

- [docs/electron.md](docs/electron.md)：Electron 架构、数据流、构建和验证记录。
- [docs/product-scope.md](docs/product-scope.md)：当前产品范围、已实现能力和边界。
- [docs/engineering.md](docs/engineering.md)：Electron 正式入口与 macOS Swift 原型归档。
- [AGENTS.md](AGENTS.md)：协作和检查约定。

`electron/` 是正式源码；`Sources/EasyLens/` 保留为 macOS 行为参考；`tmp/scripts/` 保留前期实验，不是应用入口。当前构建未做正式发布签名、公证、安装包升级或自动更新。
