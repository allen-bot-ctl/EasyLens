# EasyLens 协作入口

本仓库已从实验进入首个 macOS 工程迭代。修改前查看 Git 状态，并先读 [产品范围](docs/product-scope.md)；保留其他人的本地修改。

## 当前工程

- 正式源码在 `Sources/EasyLens/`，Swift Package 定义在 `Package.swift`，应用元数据在 `Resources/Info.plist`。
- macOS 15+ 菜单栏应用：AppKit 窗口与全局快捷键、ScreenCaptureKit 屏幕取像、Vision OCR、Accessibility 选区、系统 Translation 英译中。
- `scripts/build-app.sh` 构建 `build/EasyLens.app`；`scripts/run-app.sh` 构建并运行；`swift test` 执行快速测试。
- `tmp/scripts/` 和 `tmp/docs/` 保留实验与草稿。新功能改正式源码；实验结论整理到 `docs/`，不要把临时脚本当产品入口。
- 首个范围仅英译中。花纹、Logo、人物等方向尚未进入工程。无云端 LLM、截图持久化、分发签名、公证或自动更新。

## 修改与验证

1. 优先做小而完整的改动，保持眼睛跟随、中心词与选区优先的已验证行为。
2. 修改算法或界面后，运行 `swift test`、`sh scripts/build-app.sh`，并在可行时运行受影响的应用路径；编译不能代替实际运行。
3. 任何语言准备、屏幕读取和辅助功能权限变化，都要覆盖首次使用与失败路径。资源未就绪时不能静默尝试翻译。
4. 核对完整差异和 `git diff --check`。把事实、推断和待验证项区分写入正式文档。

用户的明确指令优先于本文件。
