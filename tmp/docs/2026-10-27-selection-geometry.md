# 鱼眼中心与选区几何命中实验

日期：2026-10-27。状态：本机原型验证；原始目标应用仍需实测。

## 要验证的假设

鱼眼只保留两个互斥模式：中心点处于系统选区时翻译整个选区；中心点不在系统选区时翻译中心词。选区命中应由辅助功能的文本位置与字形边界决定，不能由 OCR 字词相似度反推。

## 实现

- 读取前台聚焦控件的 `AXSelectedText` 或 WebKit 的 `AXSelectedTextMarkerRange` / `AXStringForTextMarkerRange`。
- 将 AppKit 鼠标坐标转为辅助功能屏幕坐标。原生文本用 `AXSelectedTextRange`、`AXRangeForPosition` 和 `AXBoundsForRange` 检查中心点是否落在选中字符边界；WebKit 用 `AXTextMarkerForPosition`、标记索引和 `AXBoundsForTextMarkerRange` 作同样检查。仅命中时直接使用完整选区文本，跳过截图、OCR 与单词翻译。选中文本不符合英文筛选时也不回退 OCR。
- 未命中时执行原来的单词 OCR 路径。剪贴板短期提示仍可辅助 OCR 修正，但不能触发完整选区翻译。异步选区译文返回时再次读取当前几何命中，防止已经离开选区的旧结果显示。
- 最多接受 1200 字符的英文选区；译文卡高度按内容增长至屏幕可用高度。超过限制、目标控件不提供选区坐标或辅助功能未授权时无法进入选区翻译。

## 证据

独立 NSTextView 与 WKWebView 测试窗口都真实高亮 105 字符、横跨两行的英文段落，未向剪贴板复制。使用 `--inspect-selection-point <x> <y>` 以 AppKit 坐标检查：

| 控件 | 第一行内部 | 第二行内部 | 第二行选区外 | 下一段 | 选区上方 |
| --- | --- | --- | --- | --- | --- |
| NSTextView | 命中 | 命中 | 未命中 | 未命中 | 未命中 |
| WKWebView | 命中 | 命中 | 未命中 | 未命中 | 未命中 |

完整运行路径在 NSTextView 选区内的固定点记录到 `SELECTION_HIT ... geometry=yes length=105`、`SELECTION_TRANSLATION requested length=105`、本地译文 `resolved=yes`，屏幕显示了整段译文；此次命中没有 `SENTENCE_FOCUS` 截图/OCR 日志。在下一段的固定点，运行日志出现 `SENTENCE_FOCUS` 和单词译文，未进入选区路径。

WKWebView 选区也完成了鱼眼运行路径：日志记录 `geometry=yes length=105 axState=text-marker`，随后本地译文 `resolved=yes`（这次约 324 ms）；没有 OCR 焦点日志。以上都是独立测试控件，不等于原始目标应用已通过。

## 复现与未验证边界

运行 `sh tmp/scripts/run_word_magnifier_probe.sh`。用 `swiftc tmp/scripts/selection_accessibility_fixture.swift -o tmp/scripts/.build/selection-fixture -framework AppKit -framework WebKit` 构建测试窗，运行 `tmp/scripts/.build/selection-fixture --web` 检查网页，去掉 `--web` 检查原生文本。`tmp/scripts/.build/EasyLensProbe.app/Contents/MacOS/EasyLensProbe --inspect-selection-point <x> <y>` 只输出状态、长度、几何命中，不输出选中文本。

目标应用的辅助功能实现可能不同，尤其是 PDF、Canvas、自绘控件和跨显示器；这些尚未验证。当前译文卡仍是不可滚动的穿透窗口，超出屏幕高度的特别长选区可能无法一次看完。普通单词模式的 OCR 误判不在本实验解决范围内。
