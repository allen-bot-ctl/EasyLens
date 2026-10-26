# macOS 本地英译中实验

日期：2026-10-26。状态：本机敏捷实验；未接云端 LLM，也不代表正式技术选型。

## 目标与方法

验证 Apple Translation 框架能否在这台 macOS 机器上将 Vision OCR 筛出的英文译为简体中文，并区分首次语言包准备耗时与语言包就绪后的翻译耗时。Translation API 要求 macOS 15 或更新版本；运行机器为 macOS 15.7.7、Intel Core i7-8569U。

先运行独立样句实验：

```bash
zsh tmp/scripts/run_local_translation_probe.sh
```

这是一个用于系统语言包确认的小窗口，不是 OCR 测试目标。输入英文后点击“本地英译中”。也可使用 `--auto --once` 对脚本内固定英文样句运行一次并退出。语言包就绪后，运行实际识别框：

```bash
zsh tmp/scripts/run_local_lens_probe.sh --local-translate
```

识别框仍用 `⌃⌥L` 唤醒、`Esc` 隐藏；停稳 1 秒后在框周围的受限上下文区域取像，由 Vision `.fast` OCR 优先选择指针附近文字，可信英文续行合并为段落；NaturalLanguage 英文门禁通过才触发 Translation。识别后可见框自适应贴合所选文字，单个错拼词也可被圈住但不一定进入翻译。按 `⌃⌥M` 切换黄色手动区域框，框内多个独立文字块可以一同选择；`⌃⌥=/-` 调宽，配合 `⇧` 调高。再次按 `⌃⌥M` 回到自动文字模式。移动或隐藏窗口时，过期译文不显示。`--quiet-text` 可使终端不打印识别文字与译文。`--once --point=x,y` 仅用于从指定 macOS 屏幕坐标进行单次自动验证，不移动鼠标，也不创建测试文字窗口。

## 实测结果

- 初次查询 `LanguageAvailability` 得到 `supported`：英文→简体中文受支持，但语言包尚未安装。系统弹出英语、简体中文下载确认；两份语言包下载完成后状态变为 `installed`。
- 固定样句 `The quick brown fox jumps over the lazy dog.` 得到 `敏捷的棕色狐狸跳过了懒惰的狗。`。首次调用约 297 秒，**包含语言包下载等待**，不能作为翻译推理延迟。语言包安装后的同一样句调用约 391 ms。
- 对真实屏幕现有内容的单次完整链路：指定屏幕坐标取像约 252 ms、Vision `.fast` OCR 约 120 ms、筛出 1 个英文片段后本地翻译约 201 ms。随后一次交互式重复取像的本地翻译约 115 ms。上述数字都只是少数几次本机样本，没有稳定尾延迟意义；完整用户等待时间还包括约 1 秒停稳门槛。
- 对另一个非英文区域单次取像：`englishSegments=0`，未进入翻译。
- 用户复测发现首次译文显示不完整、再次唤醒后只剩 OCR。排查发现：隐藏识别框时将 Translation 的任务配置清空，SwiftUI 在隐藏状态下没有可靠地观察到这次变更，后续请求因而未启动。现在每次请求都使配置失效并重新赋值；隐藏时保留配置版本，仅清除待处理文本。识别框内仍显示短预览，完整译文在旁边的可滚动、可选择文本结果窗中显示。
- 修复后用真实浏览器英文页面执行同一进程内的 `⌃⌥L → 翻译 → Esc → ⌃⌥L → 翻译`：两次取像均通过英文门禁，8/8 个英文片段获得译文，2/2 次请求启动、返回并显示完整结果；失败和过期丢弃均为 0。该样本仅验证连续唤醒链路，不代表一般屏幕内容的识别率或翻译质量。
- 全部实验 `CLOUD_LLM_CALLS=0` / `CLOUD_CALLS=0`，不保存截图。

## 链路日志与覆盖率

识别框实验将结构化事件写入 `tmp/scripts/.build/lens-probe-<run_id>.jsonl`，每次运行独立成文件，避免多进程并发写坏日志；第二实例会被进程锁阻止启动。事件包括取像完成、OCR 行数与字符数、英文候选数、自适应框选与疑似截断、扫描区和最终框尺寸、翻译请求/启动/返回/显示/失败/过期丢弃，以及各阶段耗时。日志只保存数量、尺寸和耗时，不保存截图、OCR 原文或译文。使用 `--quiet-text` 时终端也不打印文本。

```bash
sh tmp/scripts/run_local_lens_probe.sh --local-translate --quiet-text
```

启动命令会保持运行。另开一个终端执行汇总：

```bash
python3 tmp/scripts/summarize_lens_probe_log.py
```

同时只能运行一个实验实例；再次启动前，在屏幕顶部菜单栏的 `EL` 菜单选择“Quit EasyLens probe”，或在运行它的终端按 `Ctrl+C`。汇总脚本兼容 Python 3.8，默认跳过重复启动产生的空日志并统计最近一次有效运行；可加 `--run-id <ID>` 查看指定运行。报告区分“取像中有 OCR 文字”“英文门禁通过”“候选发起翻译”“任务启动”“译文返回”“完整结果窗显示”，也统计英文片段到译文片段的覆盖率和未闭合请求。没有英文候选的取像按预期跳过翻译，不能算翻译失败。一次取像可能含多个英文片段，因此同时看取像级与片段级比率。这里的覆盖率是**管线处理覆盖率**，无法衡量 OCR 漏字、语言识别误判或译文语义准确度。

## 结论与下一轮风险

本机已证明“任意屏幕位置取像 → OCR → 英文门禁 → macOS 本地翻译”可以实际运行。Apple Translation 的语言模型安装是首次使用的明显门槛，应该在真实交互之外提前准备。现在无法据此判定它比云端 LLM 在翻译质量、术语处理或长文本上更适合产品；需要后续用真实应用内容比较翻译质量、短句与混排情况，并量化移动、取消和重复翻译的延迟。

参考：[Apple Translation 框架](https://developer.apple.com/documentation/translation)、[TranslationSession](https://developer.apple.com/documentation/translation/translationsession)、[LanguageAvailability](https://developer.apple.com/documentation/translation/languageavailability)。
