# 数据来源与许可

- `electron/data/en-zh.json`：从 MIT 许可的 `ecdict` npm 包（ECDICT 数据，https://github.com/skywind3000/ECDICT）中筛选约 2.6 万条常用英汉词条，保留简短中文释义而重新生成的派生数据。MIT 许可允许复制、修改和再分发，版权与完整许可文本见 `electron/data/LICENSE-data.txt`。
- `electron/assets/ocr-sample.png`：本仓库用 DejaVu Sans 生成的 OCR 自检样张。
- OCR 语言数据：通过 `@tesseract.js-data/eng` 随包分发，来源于 Tesseract `tessdata` 项目；使用前请同时遵守其上游许可。
- 图标：`electron/assets/icon.png` 与 `electron/assets/tray.png` 为本仓库用脚本生成的简单示意图，不含第三方素材。

EasyLens 不包含任何 API Key、用户截图或运行时抓取内容。
