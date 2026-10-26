# EasyLens：保留“指向即识别”的最小交互试错

日期：2026-10-26。状态：实验记录与下一项假设；不是技术选型或产品定稿。

## 本轮纠偏

项目发起不是为了再做一个划词翻译器。划词是可靠的对照基线，不能因为镜头自动选区和整屏原位翻译失败，就直接把它定为产品主路径。要验证的是：在不可选中的屏幕内容上，是否有一种比拖框更轻、又能明确表达目标的交互。

已试错的失败模式分开记录：

| 形态 | 已观察到的限制 | 不能据此推断 |
| --- | --- | --- |
| 指针 + 自动文字块 | 相邻段落的多选/少选反复发生；停稳门槛也增加等待。 | 所有指向式输入都不可行。 |
| 手动调整镜头框 | 为纠偏反复移动/缩放，控制成本过高。 | 所有像素范围输入都不可行。 |
| 整屏翻译覆盖 | 真实页面 17 个英文块，约 2.8–4.3 秒；无关 UI 与长译框干扰阅读。 | 局部按需识别没有价值。 |

共同问题是**目标意图难以从视觉邻接关系唯一推断**。OCR 和本地翻译链路已能跑通，下一步先验证输入交互，不优化译卡或云端服务。

## 小实验 A：光标位置的辅助功能文本

只读脚本：`tmp/scripts/ax_point_text_probe.swift`。它在指定屏幕点调用 macOS Accessibility 命中测试，记录应用、元素角色、文本长度、位置到字符范围的支持和结果，不打印文字内容。系统接口依据：[Apple 位置命中](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition)、[位置到字符范围](https://developer.apple.com/documentation/applicationservices/kaxrangeforpositionparameterizedattribute)、[参数化属性查询](https://developer.apple.com/documentation/applicationservices/1461203-axuielementcopyparameterizedattr)。

本机的初步采样（屏幕坐标来自现场可视复核，不保存截图）：

| 应用 | 命中 | 观察 |
| --- | --- | --- |
| ChatGPT 桌面应用正文多点 | `AXGroup` | `AXValue` 为空，未公布 `AXRangeForPosition`；查询返回空范围。 |
| Clash Verge 页面 | `AXWebArea` | `AXValue` 为空，`AXRangeForPosition` 不支持。 |
| iTerm2 文字区 | `AXTextArea` | 公布约 4.3 万字符并支持位置范围；命中一字符，但进一步按范围取字符串失败。 |

这些点说明该 API **不是跨应用、开箱即用的指向段落能力**；它可能仍可通过子元素遍历、应用适配或不同范围 API 提升，当前采样不足以彻底排除。下一步不为此写应用专用分支，先保留证据。脚本本身可复跑：`swift tmp/scripts/ax_point_text_probe.swift` 读取指针，或追加顶部坐标 `x y`。运行须有辅助功能权限。

## 先前候选：点选 OCR 行，再按需扩展

不让算法猜唯一段落，也不要求拖出矩形。一次快捷键只截指针附近局部并 OCR；先给指针下方的**一行文字**轻量预览。用户确认这一行，必要时通过连续点选或方向键把相邻行加入；确认后才翻译并在独立浮窗中显示完整译文。一次取像和 OCR 结果供扩展复用，不随着每次微调重新取像。非英文行不进入翻译。

这项假设尚未实现。用户进一步提出先把目标缩到**镜片中心的单词**；这一方向更小，因此当前优先验证词级圆形镜片。词级结果和限制见 `tmp/docs/2026-10-26-word-magnifier-probe.md`。如果词级目标无法稳定命中，再决定是否值得回头验证点选 OCR 行；不要同时做多套复杂交互。

划词与显式截图框选保留作对照组。如果新交互在上述样本中仍无优势，再有证据讨论“业界为何多采用划词/框选”，而非提前宣布唯一答案。外部产品的公开交互也支持把两者作为基线：[Bob](https://bobtranslate.com/guide/quickstart/translate.html)、[ScreenTranslate](https://github.com/hcmhcs/screenTranslate)。
