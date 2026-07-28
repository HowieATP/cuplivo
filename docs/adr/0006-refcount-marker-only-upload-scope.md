# ADR-0006: 引用计数仅解析标记语法，孤儿检测限定 upload/ 目录

## Context

存储空间管理新增「引用计数 + 孤儿检测 + 反向定位」。消息正文中存在**两种并存的本地文件引用语法**：

1. **标记语法** `[image:path]` / `[file:path|name|mime]` —— 用户附件、MCP 工具图片、导入等写入（`message_builder_service.dart`、`message_generation_service.dart`、`mcp_tool_service.dart`）。`chat_service.dart:_extractAttachmentPaths` 只解析这一种。
2. **Markdown 语法** `![alt](/…/images/img_<hash>.png)` —— `MarkdownMediaSanitizer.replaceInlineBase64Images`（`markdown_media_sanitizer.dart:74`）把 LLM 返回的内联 base64 图片落盘到 `images/` 后，用标准 Markdown 图片语法重写。此外助手图片（`AssistantProvider` 经 `getImagesDirectory()`）存放在 `images/` 并由**助手配置**引用，根本不在消息正文里；用户理论上也可手写 Markdown 引用任意本地文件。

关键事实：`_extractAttachmentPaths` **看不见** Markdown 语法与助手配置引用。若用它对 `images/` 文件算引用计数，所有 LLM 内联图片都会得到 refCount=0 的**假孤儿**，批量删除将摧毁聊天中全部内联图片且不可恢复。这正是既有 `_cleanupOrphanUploads`（`chat_service.dart:633`）**只遍历 `upload/`、从不碰 `images/`** 的原因。

## Decision

- **孤儿检测（含「只看无引用」过滤与孤儿批量删除）限定于 `upload/` 目录**（其下图片与非图片文件均算），与已被验证的 `_cleanupOrphanUploads` 作用域完全一致。`upload/` 文件实际经由标记语法引用，引用追踪可靠。
- **`images/` 文件不进入孤儿检测**。其引用计数仅作**尽力而为的参考显示**（会漏算 Markdown 与助手配置引用），不提供基于它的删除判定。
- 引用计数与反向定位复用 `_extractAttachmentPaths` 的标记解析 + `SandboxPathResolver.fix` + 与 `_cleanupOrphanUploads` 相同的 `canon()` 路径规范化（normalize + Windows 小写）。

## Rationale

1. **数据安全优先于功能完整**：`images/` 的引用面是异构的（Markdown + 助手配置），任何漏判都是不可逆数据丢失。`upload/` 是引用追踪已被证明可靠的唯一目录。
2. **与现状清理逻辑对齐**：以 `_cleanupOrphanUploads` 的作用域为安全锚点，refCount=0 的语义即「现有清理逻辑也会删除它」，不引入比现状更激进的删除。
3. **KISS / 最小闭环**：先交付可靠的 `upload/` 孤儿清理，避免在本功能中实现健壮的 Markdown 本地路径解析（模糊、易漏）。

## Considered Options

- **扩展解析器以覆盖 `images/`**（本次拒绝，列为后续）：额外解析 Markdown `![alt](localpath)`（规范化）+ 构建「助手引用路径集合」视为永久引用，再让 `images/` 进入孤儿检测。优点是功能完整；缺点是 Markdown 本地路径解析模糊（相对路径、`file://`、容器路径漂移），任何假阴性仍是数据丢失，且改动面大。结论：作为**后续独立任务**，待 (A) 落地后再评估。

## Consequences

- **正向**：`upload/` 孤儿清理可靠、与既有清理语义一致、零新增数据丢失面。
- **反向 / 已知限制**：`images/` 文件的引用计数会**漏算**（Markdown 与助手配置引用不可见），故不用于删除判定；「只看无引用」过滤在 Images 分类下仅对来自 `upload/` 的条目生效，UX 上略不一致。需在 UI 上避免让用户误以为 `images/` 的 refCount=0 代表可安全删除。
- **残留理论风险**：用户若手写 Markdown 引用某个 `upload/` 文件，该文件会被漏算而可能在孤儿删除中丢失——但此行为极罕见，且与既有 `_cleanupOrphanUploads` 的行为一致，未使现状恶化。
- **后续债务**：实现 Markdown 本地图片引用解析 + 助手配置引用集合，方能安全地对 `images/` 做孤儿检测。
