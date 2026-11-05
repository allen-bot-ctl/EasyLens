# EasyLens

EasyLens 是 macOS 菜单栏中的英译中应用。按 **⌃⌥L** 唤出跟随鼠标的透明眼睛，停留在英文单词上可查看中文；鼠标中心落在已选文字上时，优先翻译完整选区。按 **Esc** 隐藏眼睛。非英文内容不进入翻译流程。

当前实现使用 macOS 15 及以上系统的 ScreenCaptureKit、Vision、Accessibility 和 Translation，默认本地翻译。菜单栏「设置…」可填入 DeepSeek API Key、HTTPS 接口地址并选择模型，点击「保存」后可先「测试连接」，再将翻译来源切换为 DeepSeek。密钥保存在 `~/.easylens/`（仅当前用户可读写）；选择 DeepSeek 后会向配置的接口发送待译文字，不发送或保存截图。应用只在菜单栏显示，Dock 中没有图标。

## 构建与运行

需要 macOS 15+、Xcode 16+。仓库无第三方依赖。

```sh
sh scripts/run-app.sh --show-on-launch
```

构建产物为 `build/EasyLens.app`。单独构建和运行：

```sh
sh scripts/setup-local-signing.sh  # 本机首次构建前运行一次
sh scripts/build-app.sh
open build/EasyLens.app
swift test
```

使用本地翻译时，如缺少英语或简体中文翻译资源，EasyLens 会显示说明窗口。点击「下载语言」后，macOS 会要求确认下载；可从菜单栏的「英中翻译语言」项随时重新检查。识别屏幕文字需要“屏幕与系统音频录制”权限；首次唤醒时 EasyLens 会说明并提供授权入口，未授权时不启动捕获。若系统设置的录屏应用列表里没有 EasyLens，点列表底部“＋”，在文件选择窗口按 ⇧⌘G 并输入 `build/EasyLens.app` 的完整路径；添加后按系统提示退出并重新打开应用。完整选区翻译还需要辅助功能权限，也有对应的首次使用说明。菜单栏会显示两项权限的当前状态。首次构建前运行本地签名脚本，可避免每次修改源码后反复授权。

## 仓库入口

- [docs/engineering.md](docs/engineering.md)：当前架构、语言准备、权限和验证边界。
- [docs/product-scope.md](docs/product-scope.md)：已实现的首个产品范围与后续方向。
- [AGENTS.md](AGENTS.md)：协作和检查约定。

`Sources/EasyLens/` 是正式源码；`tmp/scripts/` 保留前期实验与回归材料，不再是应用构建入口。当前 `.app` 使用本地开发签名，尚未做正式发布签名、公证或自动更新。
