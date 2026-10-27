# EasyLens

EasyLens 是 macOS 菜单栏中的本地英译中应用。按 **⌃⌥L** 唤出跟随鼠标的透明眼睛，停留在英文单词上可查看中文；鼠标中心落在已选文字上时，优先翻译完整选区。按 **Esc** 隐藏眼睛。非英文内容不进入翻译流程。

当前实现使用 macOS 15 及以上系统的 ScreenCaptureKit、Vision、Accessibility 和 Translation；不调用云端 LLM，也不保存截图。应用只在菜单栏显示，Dock 中没有图标。

## 构建与运行

需要 macOS 15+、Xcode 16+。仓库无第三方依赖。

```sh
sh scripts/run-app.sh --show-on-launch
```

构建产物为 `build/EasyLens.app`。单独构建和运行：

```sh
sh scripts/build-app.sh
open build/EasyLens.app
swift test
```

首次使用如缺少英语或简体中文翻译资源，EasyLens 会显示说明窗口。点击「下载语言」后，macOS 会要求确认下载；可从菜单栏的「英中翻译语言」项随时重新检查。屏幕读取需要系统授权；选区增强还需要在 macOS 的隐私与安全性设置中授予辅助功能权限。

## 仓库入口

- [docs/engineering.md](docs/engineering.md)：当前架构、语言准备、权限和验证边界。
- [docs/product-scope.md](docs/product-scope.md)：已实现的首个产品范围与后续方向。
- [AGENTS.md](AGENTS.md)：协作和检查约定。

`Sources/EasyLens/` 是正式源码；`tmp/scripts/` 保留前期实验与回归材料，不再是应用构建入口。当前 `.app` 仅使用本地临时签名，尚未做正式发布签名、公证或自动更新。
