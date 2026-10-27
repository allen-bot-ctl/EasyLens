# 跨应用划词与鱼眼中心命中：资料核查及 Tabbit 实测

日期：2026-10-27。性质：临时实验记录，尚非产品架构决定。

## 社区实现核查

- macOS 的普通划词翻译通常在快捷键触发后读取当前选中文本。开源 [SelectedTextKit](https://github.com/tisfeng/SelectedTextKit/tree/93dc960/Sources/SelectedTextKit) 使用辅助功能 `AXSelectedText` / 文本标记；读不到时依次考虑菜单“复制”、模拟 `⌘C`、浏览器 AppleScript。其选区位置读取同样依赖目标控件提供的几何接口。Easydict 的[说明](https://github.com/tisfeng/Easydict/wiki/FAQ)也指出有些应用不提供可靠的辅助功能划词，才使用模拟复制兜底。
- [Apple 的命中接口说明](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition)明确区分应用对象和 system-wide 对象：后者按屏幕窗口层级寻找元素。不能假定应用对象一定会返回鼠标下的网页元素。
- [Chromium 的辅助功能说明](https://www.chromium.org/developers/design-documents/accessibility/)指出浏览器为了性能可能延后建立完整树；[Electron 官方文档](https://www.electronjs.org/docs/latest/tutorial/accessibility)介绍了 `AXManualAccessibility`。这解释了浏览器差异，但不能把手动开启当作所有应用的解决方案。

普通划词翻译的“拿到选中文本”和本实验的“证明鱼眼中心恰在选区上”是两项不同要求。复制兜底只能解决前者；若无可靠坐标，直接采用复制内容会让旧选区污染新的焦点。

## Tabbit 原场景证据

在用户截图所示 Tabbit 的 Claude 页面重新选中第二段：前台聚焦元素和屏幕文字元素都返回 325 个选中字符。但 `AXBoundsForRange` 与 `AXBoundsForTextMarkerRange` 对该选区报告零尺寸，`AXRangeForPosition` 为无效的 `0:0`。此外，以 Tabbit 的 application AX 对象命中网页中心只得到菜单栏元素；system-wide 对象才找到网页文字。这说明先前在独立 Chrome Canary 页面的几何验证不能代表 Tabbit。

## 当前实验路线

1. 有可信字符或文本标记边界时，直接按中心点几何命中决定整段模式。
2. 边界不可用，但当前前台应用确有实时选区时，复用现有局部 OCR：中心词必须直接命中，所在视觉行的相邻多个英文词须与当前选区文本连续对应；命中后翻译完整的 AX 选区，而不是 OCR 片段。
3. 对不上时保持单词模式。旧选区只要与当前行不匹配，就不会提升为整段。译文异步返回后，视觉核对分支等待下一帧再次匹配才显示缓存译文。

这个兜底不写剪贴板，也不要求浏览器插件；代价是要多一次局部 OCR。短选区或大量重复文字仍有歧义，应通过更多跨应用样本决定是否引入主动复制或浏览器适配。当前没有把它们记为已解决。
