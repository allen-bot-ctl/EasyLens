# EasyLens

[项目主页](https://allen-bot-ctl.github.io/EasyLens/) · [下载最新 Release](https://github.com/allen-bot-ctl/EasyLens/releases/latest) · [从源码运行](#快速开始electron)

EasyLens 是菜单栏/托盘中的英译中应用。按 **Ctrl+Alt+L**（macOS 语义为 ⌃⌥L）唤出跟随鼠标的透明眼睛，停留在英文单词上可查看中文；按 **Esc** 隐藏眼睛。非英文内容不进入翻译流程。鼠标中心位于已选文字上时，优先翻译完整选区（Linux 使用 PRIMARY/剪贴板回退，见下文）。

当前提供 Linux x86_64、Windows x64、macOS Intel（x64）与 macOS Apple Silicon（arm64）安装包。正式可运行入口是 **Electron**：Linux 上已完成本机安装、启动、测试和打包验证；Windows x64 与 macOS 安装包由 GitHub Actions 在对应 runner 上构建。原 macOS 15+ Swift/ScreenCaptureKit/Vision/Accessibility/Translation 工程保留在 `Sources/EasyLens/` 作为行为参考，不再作为默认构建入口。

## 下载

从 [最新 Release](https://github.com/allen-bot-ctl/EasyLens/releases/latest) 按平台和架构选择：

| 平台 | 文件 |
| --- | --- |
| Linux x86_64 | `EasyLens-<version>-linux-x64.AppImage`、`EasyLens-<version>-linux-x64-dir.zip` |
| Windows x64 | `EasyLens-<version>-win-x64.exe`（NSIS 安装包） |
| macOS Intel（x64） | `EasyLens-<version>-mac-x64.dmg`、`EasyLens-<version>-mac-x64.zip` |
| macOS Apple Silicon（arm64） | `EasyLens-<version>-mac-arm64.dmg`、`EasyLens-<version>-mac-arm64.zip` |

所有安装包均未签名、未公证。Windows SmartScreen 可能要求点击“更多信息”后选择“仍要运行”；macOS Gatekeeper 可能需要在“系统设置 → 隐私与安全性”中允许，或右键点击应用后选择“打开”。

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

`npm run dist` 会尝试生成 AppImage；本仓库的默认本地验证目标是 `dir`，避免依赖额外的打包工具链。

其他平台的安装包需要在对应系统上构建，或交给 GitHub Actions：

```sh
# Windows x64
npx electron-builder --win nsis --x64 --publish never

# macOS Intel（x64）和 Apple Silicon（arm64）
npx electron-builder --mac dmg zip --x64 --arm64 --publish never
```

`--publish never` 用来阻止 electron-builder 在检测到 tag 时自动发布；所有平台产物由发布 job 统一上传。

## 发布流程

1. 更新 `package.json` 的 `version`，确认 `npm test` 通过并提交到 `feat/gbot`。
2. 创建与版本对应的 tag，例如 `v0.1.0`。
3. 推送 tag 触发 `.github/workflows/release.yml`：

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

4. Actions 会并行构建 Linux x86_64、Windows x64、macOS x64 与 macOS arm64，最后用一个 publish job 创建 Release 并上传全部安装包。

## 使用

- **Ctrl+Alt+L**：显示或隐藏眼睛。**Esc**：隐藏。
- 鼠标移动时眼睛跟随；停稳约 100ms 后读取鼠标附近画面并识别英文。
- 单词优先使用随包内置的英汉词典（ECDICT 子集，离线）。找不到时不会编造译文。
- 默认不保存截图；只有设置 `EASYLENS_DEBUG_CAPTURE=1` 时才会把最近一帧写到系统临时目录用于诊断。
- 托盘菜单的「设置…」可选择本地词典或 DeepSeek，填写 HTTPS 接口地址、模型和 API Key，并可测试连接。
- DeepSeek API Key 保存在 `~/.easylens/deepseek-api-key`（目录 `0700`、文件 `0600`）；非敏感设置保存在 `~/.easylens/settings.json`。密钥不会写入仓库。
- 选择 DeepSeek 时，待译文字会发送到配置的 HTTPS 接口；截图不会上传。
- 运行日志写入 `~/.easylens/easylens.log`（超过约 5MB 自动轮换为 `easylens.log.1`）；托盘菜单和设置窗口的「查看运行日志…」可直接打开。

## Electron 版本的能力差距（以 Linux 为主要验证环境）

Windows x64 与 macOS 安装包由 CI 构建，但本仓库尚未在这些系统的真机上完成完整功能验证；下表主要记录 Electron 入口相对原 macOS 原生实现的差异。

| macOS 原生能力 | Electron/Linux 现状 |
| --- | --- |
| ScreenCaptureKit 取像并排除自身窗口 | Electron `desktopCapturer`；拍照前短暂隐藏眼睛窗口，避免遮住目标文字。 |
| Vision OCR | Tesseract.js + 随包 `eng` 语言数据；只识别英文，复杂字体、低分辨率和暗色界面的准确率低于 Vision。 |
| Accessibility 读取任意应用选区与命中几何 | 读取 X11/Wayland PRIMARY（Electron `clipboard` 的 `selection` 类型，必要时回退到 `wl-paste`、`xclip`、`xsel`）或近期剪贴板提示；没有精确 AX 命中几何，可能把陈旧选区误判为当前选区。 |
| macOS Translation 本地英译中 | 无系统翻译框架。单词使用内置词典；长选区只能逐词释义，质量明显低于真正的机器翻译；需要完整译文时请配置 DeepSeek。 |
| 菜单栏 `LSUIElement` | 托盘应用 + `skipTaskbar`；主要 Linux 桌面可能需要 AppIndicator 扩展才能显示托盘图标。 |
| 录屏/辅助功能 TCC 授权流程 | macOS 首次使用需在系统设置授予 EasyLens 屏幕录制权限，托盘菜单和翻译卡会提示并可直接打开授权页；Wayland 下屏幕捕获由 PipeWire/portal 管理，首次可能弹系统授权。若捕获为黑屏，优先在 X11 会话运行。 |
| 原生毛玻璃眼睛 | Canvas 绘制近似透明眼睛，中心保持透明；不依赖原生材质。 |

## 原 macOS 工程（参考）

`Sources/EasyLens/`、`Package.swift`、`Resources/Info.plist` 与 `scripts/build-app.sh` 等仍保留，需要 macOS 15+、Xcode 16+ 才能构建。原行为说明和权限细节见 [docs/engineering.md](docs/engineering.md) 的归档部分。

## 仓库入口

- [docs/electron.md](docs/electron.md)：Electron 架构、数据流、构建和验证记录。
- [docs/product-scope.md](docs/product-scope.md)：当前产品范围、已实现能力和边界。
- [docs/engineering.md](docs/engineering.md)：Electron 正式入口与 macOS Swift 原型归档。
- [AGENTS.md](AGENTS.md)：协作和检查约定。

`electron/` 是正式源码；`Sources/EasyLens/` 保留为 macOS 行为参考；`tmp/scripts/` 保留前期实验，不是应用入口。当前所有平台构建均未做正式代码签名、公证、安装包升级或自动更新。
