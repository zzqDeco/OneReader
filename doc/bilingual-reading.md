# 段落级双语阅读

双语入口位于阅读辅助的「双语」页。用户明确加载当前章节/页或选区后，先看到原文范围和预计发送量，再选择翻译。Markdown、纯文本、受控 HTML/网页、EPUB 与文本 PDF 使用已有原生阅读界面，译文保留在辅助区域；代码界面不启动代码语义翻译。扫描 PDF/图片只有在当前 AdapterPlan 的 read 路由提供有效 OCR 文字后才可翻译。

## 原文与生成结果

- Markdown 段落/标题来自 AST 的 UTF-8 source range，再转换为原文 UTF-16 范围；HTML/EPUB 使用受控 DOM 中的段落和稳定 DOM path；PDF 保持页码，段落以原文 quote 和页内文本范围关联。
- HTML/EPUB 的行内选区先从实际 DOM 节点向上寻找所属正文块，只在该块内验证唯一原文；缺失、多义或无法归属的选区会拒绝，不会扫描到其他重复段落。
- `TranslationSegment` 包含真实 SourceFragment、Snapshot、Locator、原文 digest；相同文字的不同段落有不同 ID。译文没有字符 Locator，复制的是纯文本，不执行模型生成的 HTML/脚本。
- 代码块、原始 HTML 块不翻译；行内代码、公式和链接目标使用宿主 placeholder，输出必须完整保留，宿主恢复后展示。原文语言自动模式不是确定的语言检测结论，用户可手动纠正。
- 每批最多 12 段、12,000 原文 UTF-16 units，单段最多 4,000。过长内容只加载有界阅读单元，不后台预取整本书。

## 单 Agent 与隐私

`translateFragments` 属于现有 Reading Agent，不创建第二个模型代理。请求只发送声明的段落以及源/目标语言；不恢复历史 transcript，也不向模型注册读取工具。宿主在发送前验证当前快照与真实 observation，完成时验证 ID 集合、顺序、digest、placeholder 和长度。Provider endpoint、Keychain、模型预算、超时、用户披露、generation 和 manifest CAS 沿用现有边界。

未确认远程披露时不构建模型，UI 显示发送范围并可拒绝。每次串行请求一个段落；只有成功、完整、验证通过的输出在 Agent 完成事务中写缓存。已发送但没有确认结果的请求不可声称未计费；取消、失败、断线后重试界面明确提示可能重复计费。重试先读取缓存，不再请求成功段落。

## 缓存与迁移

数据库 v13 `translation_cache` 为派生数据，Agent runtime schema 从 5 升至 6；旧 Run 保留，并继续按现有启动恢复策略标记未完成运行。cache key 包含原文 Source/Snapshot/段落锚点与 digest、源/目标语言、Provider destination/model/revision、prompt v1 和 schema v1。更换源版本、语言、模型或 Provider 配置不能误命中。

已配置模型的缓存可完全离线加载，无需调用 Provider；无缓存明确显示「尚未翻译」，不影响原文。删除只影响当前段落/语言/模型缓存，不删除 Source、标注或阅读进度。历史 Agent audit/output 保留，不把清缓存误作审计删除。

## 阅读行为

macOS 辅助面板与原文并排；iPhone 辅助页支持按段落对照、只看原文、只看译文。文字可选中复制，段落提供「返回原文」和「在对应原文上标注」。标注前确认并跳转原文，绝不生成译文字符范围作为原文范围。

只有用户实际滚动译文才将对应原文段落锚点交给现有进度存储。切换布局、语言、自动恢复或可选「跟随原文」的程序化滚动不推进进度；关闭/重启使用同一原文锚点。原文位置采集不会在用户正在读译文时用隐藏原文视口覆盖进度。

恢复与「跟随原文」只在已加载的有界段落集内匹配，优先稳定 Locator、精确偏移与半开原文范围，再使用唯一的 rect、DOM 所属块或行范围。只有同页/同行的粗粒度位置且存在多个候选时保持当前位置，不再默认跳到第一段。

OCR 译文的缓存和引用保留完整 OCR revision/span Locator；持久化阅读进度则映射回原始 PDF/图片页，保留有效原页 rect 并移除 OCR quote/fingerprint 与派生文本偏移，避免把识别结果误记为原文件文字。

## 验证边界

假 Provider 回归覆盖 Unicode/重复段落/选区、AST/DOM、受保护内容、缓存键、输出乱序/缺段/伪造/过长、取消后迟到结果、披露拒绝零调用、部分完成重试与重启缓存。真实模型质量、macOS 宽窄窗口、iPhone 横竖屏/VoiceOver 的可见验收须在集成后执行，不能以单元测试替代。
