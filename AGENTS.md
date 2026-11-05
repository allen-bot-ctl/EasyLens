# EasyLens 协作入口

本仓库的正式运行入口已迁移到 Electron。修改前查看 Git 状态，并先读 [产品范围](docs/product-scope.md)；保留其他人的本地修改。

## 当前工程

- 正式源码在 `electron/`，入口与脚本定义在 `package.json`；Electron 主进程在 `electron/main.js`。
- Linux 托盘应用：托盘与全局快捷键、透明跟随鼠标的眼睛、`desktopCapturer` 取像、Tesseract.js OCR、PRIMARY/剪贴板选区回退、内置英汉词典英译中，以及可选的 DeepSeek 远端翻译。
- `npm start` 只驻留托盘，`npm run start:show` 启动后显示眼睛；`npm test` 执行纯逻辑与存储测试，`npm run test:ocr` 验证随包 OCR 数据，`npm run build` 生成 `dist/linux-unpacked/`，`npm run smoke` 在 Xvfb 中启动真实进程做冒烟检查。
- `Sources/EasyLens/`、`Package.swift`、`Resources/Info.plist` 和原构建脚本保留为 macOS 15+ Swift 原型，需要 Xcode 才能构建，不是默认入口。
- `tmp/scripts/` 和 `tmp/docs/` 保留实验与草稿。新功能改正式源码；实验结论整理到 `docs/`，不要把临时脚本当产品入口。
- 首个范围仅英译中。花纹、Logo、人物等方向尚未进入工程。远端仅支持用户配置的 DeepSeek；无截图持久化、正式分发签名、公证、安装包升级或自动更新。

## 修改与验证

1. 优先做小而完整的改动，保持眼睛跟随、中心词与选区优先的已验证行为。
2. 修改算法或界面后，运行 `npm test`、`npm run test:ocr`、`npm run build` 和 `npm run smoke`，并在可行时运行受影响的应用路径；编译或打包不能代替实际运行。
3. 任何屏幕读取、选区、OCR 和翻译来源变化，都要覆盖首次使用与失败路径：捕获失败、未识别到英文、词典未收录、DeepSeek 未配置密钥或请求失败时不能静默展示臆造译文。
4. 不要提交 API Key、`~/.easylens` 内容、`notes/` 或 `artifacts/`。核对完整差异和 `git diff --check`，并把事实、推断和待验证项区分写入正式文档。

用户的明确指令优先于本文件。
