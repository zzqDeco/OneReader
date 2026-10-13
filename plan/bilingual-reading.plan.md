# 段落级双语对照阅读实施计划

Issue #25。基线 `origin/dev` / `a3c5b241d8678c806cf2f4a5d04cf21c2f909063`。

## 不变量与边界

- 原文 Snapshot、SourceFragment 和 Locator 是唯一证据；译文只保存原文段落锚点，不把译文偏移写成原文位置。
- 沿用单 Reading Agent，新增有类型的 `translateFragments` 请求与响应。宿主验证 ID 顺序、内容 digest、快照与 Provider binding 后才写入有效缓存。
- 原生 Reader 主界面始终可用。当前单元或明确选区有界生成，不自动翻译整本书。扫描件需有效 OCR 文本；纯文本能力独立工作。
- 缓存按 Source/Snapshot、段落 digest、语言、Provider destination/model/revision、prompt/schema 分区。只清理派生译文，不删除原文、进度或标注。
- 远程发送复用 Provider 披露、Keychain、端点限制与 generation/manifest CAS。取消/断流/迟到结果不提交；已完成的独立段落可重试复用。发送后未确认的片段提示未知及可能重复计费。

## 实施切片

1. [x] 受控分段、选区与格式保留契约；本地 fake fixtures。
2. [x] 有类型 Agent 任务、输出验证、受限发送与宿主缓存提交。
3. [x] DB v13 译文缓存及 Agent runtime schema 升级；重启恢复与离线读。
4. [x] 原生双语辅助面板、语言/布局/跟随开关、取消/重试/删除缓存及原文定位。
5. [x] 假 Provider 回归测试，文档与源码索引；仅本地 commit。

## 预算与 schema

- 首版每批最多 12 段、原文最多 12,000 UTF-16 units；单段最多 4,000 units。
- 串行段落批次，单 Reading Agent 保持现有 tool/model/response limits；未完成输出永不作为成功缓存。
- 译文缓存 schema 1 / prompt 1，DB 迁移预留 v13；Agent runtime schema 6。缓存不含 secret。完成时间及 Provider 展示信息随缓存保存。

## 验证与交付

- `swift test --jobs 2`（bootstrap 既有固定依赖）；结构映射、Unicode、代码/链接/公式、伪造/重复/漏段/乱序输出、缓存分区/删除/重启、取消/迟到结果、披露拒绝零外发。
- `python3 scripts/check-doc-index.py`、`git diff --check`。
- 不运行并发 Xcode/device 验证、不创建/启动 Simulator、不触碰真实 Library、用户材料或真实模型。原生可见验收由集成负责人执行，不以单元测试替代。

## 当前状态

2026-10-13：实现完成。首次 `swift test --jobs 2 --skip-update` 完成 265 项，4 个失败均为 schema 元数据旧断言，已同步为当前 schema；其余通过。最终 `swift test --jobs 2 --skip-update --filter 'TranslationTests|ReleaseMetadataTests|AppModelLibraryTests.testV[89]'`：18/18 通过（15 个双语测试、2 个旧库迁移回归、1 个 schema metadata）。文档索引校验通过（78 Markdown 文件），`git diff --check` 通过。依赖 pin 与 app 版本未改；CI、集成后全量、macOS/iPhone 原生可见验收、真实模型质量及发布均未执行，交由集成门禁。

### PR #29 复审修复

- [x] HTML 行内选区沿实际 DOM 祖先解析所属正文块；缺失、多义或 owner 内重复文字时拒绝，不回退扫描首段或其他段落。
- [x] 双语恢复/跟随使用稳定 Locator、原文半开偏移和唯一候选匹配，同页/同行有多段时不粗略选中首段。
- [x] 新增 7 项回归覆盖重复 HTML 文本、嵌套列表行内选区、错误 DOM path、PDF 40–45 边界、同行分段、原文范围与 OCR rect。
- [x] `swift test --jobs 2 --skip-update --filter TranslationTests`：22/22 通过；文档索引（78 Markdown 文件）与 `git diff --check` 通过。获授权后提交并推送既有 PR #29；原生集成验收由根任务串行执行，本次未运行 release/native 构建。
