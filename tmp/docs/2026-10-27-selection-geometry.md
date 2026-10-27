# 鱼眼中心与选区几何命中实验

日期：2026-10-27。状态：本机原型验证；已增加独立 Chromium 客户端的跨应用运行验证，原始目标应用仍需复测。

## 要验证的假设

鱼眼只保留两个互斥模式：中心点处于系统选区时翻译整个选区；中心点不在系统选区时翻译中心词。选区命中应由辅助功能的文本位置与字形边界决定，不能由 OCR 字词相似度反推。

## 实现

- 从前台应用中鼠标下的控件及其父元素读取 `AXSelectedText` 或 `AXSelectedTextMarkerRange` / `AXStringForTextMarkerRange`；必要时检查聚焦控件。
- 将 AppKit 鼠标坐标转为辅助功能屏幕坐标。原生文本用 `AXSelectedTextRange`、`AXRangeForPosition` 和 `AXBoundsForRange` 检查选中字符；网页文本优先用 `AXTextMarkerForPosition` 和字符边界，接口不可用时按视觉换行的文本标记检查。仅命中时直接使用完整选区文本，跳过截图、OCR 与单词翻译。选中文本不符合英文筛选时也不回退 OCR。
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

## 跨应用修正与复测

用户截图显示 ChatGPT 客户端中的一整行英文仍处于高亮状态，但鱼眼只翻译 `morning`。对该客户端的辅助功能读取证实：焦点元素可能是输入框，而高亮文字属于鼠标下的网页内容元素；此前只读取焦点元素，会错过真实选区。另外，它虽提供选区文本和文本标记边界，`AXRangeForPosition` 却返回无效的 `0:0`，不能将该结果作为选区未命中的结论。

现在从前台应用中鱼眼中心下方的元素开始，沿辅助功能父元素查找当前选区；只有中心点落在选区字形几何范围内，才立即翻译完整选区。原生控件优先使用字符范围；网页控件没有可靠的鼠标字符标记时，按视觉换行的文本标记逐行检查。完整选区的外接矩形仅用于快速排除，不直接判断命中，以免相邻行或行尾空白产生误判。异步译文返回时仍重新检查中心点及选区文本，过期结果不会显示。

独立 Chrome Canary 进程以 `--force-renderer-accessibility` 打开 `tmp/scripts/selection_chromium_fixture.html`，页面由浏览器自身创建高亮选区，EasyLens 未控制它的选区内容。选区起止偏移为 5 至 120，覆盖第一行的一部分与第二行的一部分。固定点检查：第一行选中处命中、第二行选中处命中、第二行未选中的右侧及下一行均未命中。完整运行时记录 `SELECTION_HIT ... length=115`、`SELECTION_TRANSLATION requested length=115`、`resolved=yes`；同一浏览器页面指向未高亮部分，记录 `SENTENCE_FOCUS` 与 `FOCUS_TRANSLATION`，未进入选区翻译。实验使用单独浏览器进程，因此验证的是跨应用辅助功能路径，而非 EasyLens 自身窗口。

复现边界：目标 ChatGPT 客户端原先那条选区在检查时已经消失，暂时无法复现用户截图的原样运行结果。其他应用还可能缺少文本选区、标记或字形边界接口；这些情况仍走单词 OCR，不凭截图颜色猜测高亮。选区判断不依赖剪贴板。

## Tabbit 复测修正

上述“原始目标应用仍需复测”的边界已在同日补做。用户的新截图来自 Tabbit 的 Claude 页面，并非独立 Chrome Canary 页面。该应用返回了完整选中文本，却对文本范围提供零尺寸边界，导致前一版仍显示单词卡。资料调查、辅助功能观测和新的 OCR 辅助定位记录见 [跨应用选区调研](2026-10-27-cross-app-selection-research.md)。

在 Tabbit 页面选中 325 字符、鱼眼指向选中文字后，运行日志记录 `SELECTION_HIT source=accessibility-visual length=325`，接着发起并完成本地整段翻译；截屏也确认显示“选区翻译”卡。此分支只在几何接口不可用、且焦点行与当前实时选区连续匹配时启用。它不是证明所有应用都提供精确选区几何。长译文卡的文本高度曾低估；复测中加大按实际控件测得的高度后，截屏确认尾句“我可以帮助你整理它。”完整可见。

保持第二段高亮不变，将固定鱼眼中心移到上一段未选中的 `It's`：运行日志只有 `SENTENCE_FOCUS` / `FOCUS_TRANSLATION`，屏幕显示单词卡，没有 `SELECTION_HIT`。这验证了同一页面上“选中段落”和“未选中行”的两种路径。
