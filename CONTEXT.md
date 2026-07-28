# Cuplivo Domain Glossary

## Title Preset System
- **Hash Fingerprint matching**: `detect()` uses `trim()` only (conservative), exact character match after stripping leading/trailing whitespace.
- **PromptPreset data class**: `id`, `label`, `prompt` fields only. No `recommendedThinking` — presets are style-only, Thinking is independently controlled.
- **Dirty state**: real-time `detect()` on every text change; dropdown label switches to "自定义" when content no longer matches any preset.

## UI Interaction Model
- **Desktop** uses `DesktopSelectDropdown<String>` with `__custom__` sentinel for unmatched prompts.
- **Mobile** opens a `showModalBottomSheet` with `IosCardPress` options.
- Both are wrapped in `ListenableBuilder(controller)` so the dropdown label updates immediately on preset click or text edit, without auto-saving.
- "重置全部" button: resets both prompt text (`resetTitlePrompt()`) and Thinking switch (`resetTitleGenerationThinkingEnabled()`). No separate [↺] on the Thinking row.

## Prompt Preset Screen Layout

```
┌──────────────────────────────────┐
│ _TitleThinkingSwitchRow          │
│                                  │
│ 提示词              [▼ 标准✓]   │
│                                  │
│ ┌──────────────────────────────┐│
│ │ 可编辑文本框                  ││
│ └──────────────────────────────┘│
│ 可用变量: {content} {locale}    │
│ 更改预设后需点击「保存」方可生效 │
│                                  │
│ [重置全部]              [保存]   │
└──────────────────────────────────┘
```

## Title Generation Prompts

- **emojiTitlePrompt**: A preset variant of the title generation system prompt that allows ONE relevant emoji at the beginning of the title (followed by a space). No other punctuation or special characters are permitted elsewhere. The character limit (≤10) excludes the emoji.

## SVG Rendering in Chat

- **SVG code block** (` ```svg `): rendered via `SvgCodeBlock` widget (tab UI: "SVG" image tab + "Code" tab, reuses `mermaidImageTab`/`mermaidCodeTab` ARB keys). Uses `SvgPicture.string()` to render inline SVG XML. No streaming support (streaming SVG fragments are almost always invalid XML).
- **Markdown image SVG**: `imageBuilder` detects `.svg` extension in URL and `data:image/svg+xml;base64,...` pattern, routes to `SvgPicture.network()` or `SvgPicture.string()` respectively.
- **Known limitation**: URLs without `.svg` extension (e.g. shields.io badges like `https://img.shields.io/badge/release-1.0.0-blue`) are not detected as SVG. The user must ensure LLM output includes `.svg` suffix, or append it manually. Deliberate trade-off: avoids an extra failing HTTP request for every extensionless URL.

## Input Draft Persistence

- **InputDraftPersistence**: `lib/features/home/services/input_draft_persistence.dart`. Owns debounced (800ms) writes + lifecycle immediate save of chat input draft via `SharedPreferences`.
- **Scope**: Single global draft (`chat_draft_v1` key). Not per-conversation — the input is shared across conversations.
- **Persistence**: JSON blob with `{text, images[], documents[{path,fileName,mime}]}`.
- **Restore**: On cold start only, in `_ChatInputBarState._restoreDraft()`. Sets `TextEditingController.text` + media lists.
- **Clear**: On send success or when input is fully empty. Debounce skips empty content.

## Incremental Backup (Experimental)

- **Data scope**: Chat data (conversations + messages + toolEvents + geminiThoughtSigs). Optionally includes files (upload/, images/, avatars/, fonts/) when `includeFiles=true`, filtered by mtime >= since.
- **Filtering unit**: Message-level (`message.timestamp >= since`). Conversations created before `since` are still included if they have recent messages; only those messages are exported. Uses `updatedAt` as a fast pre-filter to skip inactive conversations. See `docs/adr/0002-conversation-level-incremental-filtering.md`.
- **File naming**: `cuplivo_incr_<export_ts_YYYYMMDD-HHmmss-ffffff>_<since_ts_YYYYMMDD-HHmmss>.zip`. The `cuplivo_incr_` prefix is the single identification mechanism for the restore path.
- **Restore behavior**: `cuplivo_incr_` prefix detected → skip the "Overwrite/Merge" dialog entirely → force `RestoreMode.merge` at both UI and DataSync layers.
- **Date source**: `BackupReminderProvider.lastBackupTime` for the [↻] shortcut. If null, fallback to 30 days ago. User can always override via `showDatePicker()`.
- **`includeSettings`**: Default `true`. Not yet persisted (planned for a future PR).
- **`includeFiles`**: Default follows the config's `includeFiles` toggle. Files are filtered by `lastModifiedSync() >= since`. Not persisted.
- **Architecture**: Incremental backup is NOT a mode toggle on full backup — it's a separate independent action. `BackupProvider.incrementalBackup(IncrementalBackupConfig)` and `S3BackupProvider.incrementalBackup(IncrementalBackupConfig)` are new methods that don't modify existing `backup()`.
- **UI placement**: Desktop & Mobile. Each target (WebDAV, S3, Local) gets its own incremental section within its existing card, with date picker + [↻] shortcut + settings toggle + includeFiles toggle + separate action button.
- **User-visible behaviors**:
  - Export filename always starts with `cuplivo_incr_`
  - Export includes settings if `includeSettings=true`, includes files if `includeFiles=true` (filtered by mtime)
  - Import automatically skips mode selection for `cuplivo_incr_` files
  - Empty export (0 conversations matched) shows a confirmation warning before producing the file

## Multi-AI Comparison Mode (Side-by-side)

- **Trigger**: 
  - **User messages**: No entry point.
  - **Assistant messages**: MessageMoreSheet "Multi AI" action → "让其他 AI 也回答". Uses pre-selected models from model selector; if none pre-selected, opens multi-model selector via `showMultiModelSelector()`. Comparison starts **immediately** via `startRoundFromHistory()`.
  - **Model selector**: Dual-mode (single/multi) in `_ModelSelectSheet`. Select ≥2 models → 确定 → enters multi-AI mode via `multiAIEngine.enter()`.
- **Data model**: `ChatMessage.subgroupId` (nullable TEXT). Within the same `groupId`, multiple `subgroupId`s represent different model responses as **cards**. `subgroupId = null` messages follow existing collapse/version behavior.
- **Card rendering**: When a `groupId` has any message with `subgroupId != null`, render cards (PageView) instead of a single collapsed message. Each card shows one subgroup's selected version using full `ChatMessageWidget`.
- **Resolve (adopt)**: ALL threads across ALL rounds get `subgroupId = NULL`, reassigned continuous versions, adopt version stored in `versionSelections[groupId]`. Exits card mode. Exits multi-AI engine mode.
- **Drop**: A single thread's messages get `subgroupId = NULL` (keeping version), exits that card but stays in version pool. Model pool shrinks by 1 via `removeThread()`. Physical DB rows unchanged.
- **Streaming**: N concurrent streams, each writing to their own messageId. Existing `StreamingContentNotifier` per-message architecture handles this.
- **Engine state** (MultiAIEngine, in-memory only): `_models`, `_threadIds`, `_isActive`. NOT persisted — recovery happens from `ChatMessage.subgroupId` + `providerId`/`modelId` in conversation history.
- **Persistence recovery**: On conversation switch via `switchConversationAnimated`, scan `_messages` for `subgroupActiveGroupIds`, extract `{providerId, modelId}` from latest round's subgroup messages, restore model selector badge via `multiAIEngine.recoverFromMessages()`.
- **Mode lifecycle**:
  - Enter: Select ≥2 models → 确定. Or: assistant message "更多" + trigger.
  - Lock: Once active, model selector button is locked → shows pill badge with ✕ and model count. Click shows snackbar "多 AI 模式已激活".
  - Exit: Click ✕ on badge, resolve (adopt), deselect to 1 model, switch conversation.
  - Drop: Reduces model pool synchronously via `removeThread()`.
- **Model selector interaction**:
  - Normal: single-select (existing behavior).
  - Multi-select mode: checkboxes in `_ModelSelectSheet` + 确定 button. Long-press still opens ProvidersPage.
  - When N≥2 selected → enter multi-AI mode.
  - When locked: click → snackbar toast.
- **Send behavior**: When multi-AI mode active, typing send triggers `startRound` for ALL models (N parallel threads).
- **startRoundFromHistory**: Called when user clicks "让其他 AI 也回答". Finds preceding user message, assigns it `roundGroupId` (persisted via `chatService.updateMessage` with `groupId`), creates N assistant placeholders with `subgroupId`s, starts N streams using conversation history as API context. No new user message created.
- **UI**: `MultiAICardGroup` with PageView (horizontal swipe). Card has Resolve ✓ / Drop ✕ per card. `ChatInputBar` retained with badge `{count} 个模型` and ✕ button.

## Image Attachment Compression

- **Trigger**: Per-image via clicking file size label below thumbnail; batch via dialog's "全部压缩" button. All ingress paths (gallery, camera, file picker, drag-and-drop, clipboard paste) treated identically.
- **Dialog**: `ImageCompressionDialog` in `lib/shared/dialogs/image_compression_dialog.dart`. Follows incremental backup pattern: `show()` for desktop (centered Dialog), `showSheet()` for mobile (bottom sheet). Same content, different shell.
- **Dialog controls**: Quality slider (30-100), max-dimension slider (320 to original long-edge, step 64px, shortcuts: 原始 / 1/2 / 1/4), format option (仅在有 alpha 通道的 PNG 时显示: "保留透明度 PNG" / "转为 JPEG 白色背景").
- **Format detection**: Done in `_openCompressionDialog` via `img.decodeImage()` (pure Dart, no GPU). Detects real pixel transparency (`decoded.hasAlpha && any(px.a < maxChannelValue)`). Result passed to dialog as `hasRealAlpha`. Eliminates separate file header parsing.
- **Compression core**: `ImageCompressor.compressIfNeeded()` in `lib/utils/image_compressor.dart` (credit: Ankairis, PR #705). Decode/encode in background isolate via `compute()`. Parameters: `quality` (1-100), `maxDimension` (resize longest edge, maintain aspect ratio), `keepPng` (override format detection). Defensive: on exception or result≥original, return original path unchanged.
- **File strategy**: Compressed result written to same dir, same basename, new extension (e.g. `photo.png` → `photo.jpg`). Original file deleted. `_images` path updated accordingly.
- **UI**: File size shown as gradient overlay at bottom of each 64×64 thumbnail, with `Lucide.ImageDown` icon. Tappable → opens dialog. `_imageSizes` cache maintained alongside `_images` to avoid repeated disk reads.
- **Compression progress**: Dialog buttons show loading spinner while compressing. Single "压缩" or "全部压缩" (后者仅在 totalImageCount > 1 时可用).

### One-Click Compression (Quick Compress)

- **Purpose**: Shorten the discovery path for image compression. Eliminates the per-image "tap → adjust params → compress" flow for the common case.
- **Settings** (stored in `SettingsProvider`, SharedPreferences):
  - `oneClickCompressEnabled` (bool, default `true`): gates the button and all behavior below.
  - `oneClickCompressMaxLongEdge` (int, default `1536`, range 768–4096, step 256): if an image's long edge ≤ this value, skip entirely (no decode, no re-encode). Rationale: Google Gemini splits images into 768×768 tiles; 2×768 = 1536 minimizes token usage.
  - `oneClickCompressQuality` (int, default `75`, range 50–95, step 5): JPEG quality for re-encoding.
  - `oneClickCompressAlwaysJpg` (bool, default `false`): when true, flatten alpha PNGs to JPEG (white background, non-configurable). When false, alpha PNGs are re-encoded as PNG (preserving transparency).
- **Settings UI**: New section card in Display & Behavior settings (mobile: `display_settings_page.dart`, desktop: `display_pane.dart`), placed after the image cropper toggle. Enabled toggle gates visibility of the other 3 rows (hidden when disabled). Long-edge and quality are sliders with trailing value labels.
- **Button**: Trailing item in the image preview strip (`ListView`), same 64×64 slot as thumbnails. Icon: `Lucide.Zap`. Tooltip: localized `oneClickCompressTooltip`. Visible when `_images.isNotEmpty && oneClickCompressEnabled && !_oneClickCompressing && !_oneClickCompressDone`.
- **Lifecycle**:
  - Tap → button slot becomes `CupertinoActivityIndicator` (64×64), send button disabled, entire strip interaction-locked (no ✕ remove, no size-overlay tap).
  - Iterates ALL `_images` through `ImageCompressor.compressIfNeeded()` with settings params (`maxDimension` = longEdge setting, `quality` = quality setting, `keepPng` = `!alwaysJpg || hasRealAlpha`).
  - Already-compressed images are naturally skipped (longEdge ≤ threshold after first pass). No separate tracking set.
  - On completion: if ≥1 image compressed → aggregate snackbar "已压缩 N 张，节省 X MB"; if zero → "无需压缩". Button vanishes (`_oneClickCompressDone = true`).
  - `_oneClickCompressDone` resets to `false` in `_addImages` (new image arrives → button reappears).
- **Relationship to per-image dialog**: Coexists. The dialog remains available for manual per-image control (full 30–100 quality, arbitrary dimension, explicit format choice). One-click is the fast path; dialog is the precision path.

## Skill System

### Core Concept

- **Skill**: A directory at `<appData>/skills/<name>/SKILL.md` containing a specialized instruction set + optional auxiliary files (scripts/, references/, assets/). The directory name IS the skill's identity — it must match the `name` field in YAML frontmatter and follow AgentSkills naming rules (lowercase letters, digits, hyphens; ≤64 chars; no leading/trailing/consecutive hyphens). Auxiliary files are readable by the model via `read_skill_file`.
- **`SkillManager`**: The facade that owns all skill CRUD. Reads SKILL.md from disk lazily — no memory cache. Atomic write pattern: staging dir → rename target→backup → rename staging→target → cleanup. Path safety: rejects names containing `/`, `..`, leading/trailing dots, and whitespace. Frontmatter parsing uses the `yaml` package (not a hand-rolled line parser).
- **`AppDirectories.getSkillsDirectory()`**: Returns `<appData>/skills/`. Each skill lives in its own subdirectory matching the skill name.

### Lifecycle

- **Import** (three channels, all funnel to `SkillManager.saveSkill()`):
  - Manual paste: User pastes complete SKILL.md (YAML frontmatter + body) into a text box. Real-time frontmatter parsing + name validation.
  - File picker: System file picker selects a single `.md` file or `.zip` archive. ZIPs are scanned for all `SKILL.md` files (any nesting depth), each validated and imported independently.
  - GitHub URL: User pastes a `github.com/{owner}/{repo}[/tree/{branch}[/sub/path]]` URL. App downloads the repo archive ZIP from `github.com/{owner}/{repo}/archive/refs/heads/{branch}.zip` (no API rate limit, no auth for public repos), then reuses the same ZIP import pipeline (scan for all `SKILL.md` at any depth, multi-select dialog if >1 found). If a subpath is specified, the scan is scoped to that subdirectory. Private/missing repos return 404 → localized "not found or private" error. GitHub only — no GitLab/generic git hosts.
- **Update**: Re-import with the same name overwrites the directory. Atomic write handles crash safety.
- **Delete**: `SkillManager.deleteSkill(name)` removes the directory. Removes from all assistants' `skillIds` (orphan cleanup).
- **Export**: Included in backup via `_packZipSync` — `skills/` directory packed independently of `includeFiles`, always included. Incremental backup uses mtime ≥ since filtering (same mechanism as upload/avatars/images/fonts).

### System Prompt Injection

- **`<available_skills>`**: An XML block injected into the system prompt listing only the skills the current assistant has bound. Contains `name` + `description` only (progressive disclosure level 1). Excludes disabled or unbound skills.
  ```xml
  <available_skills>
    <skill>
      <name>pdf-processing</name>
      <description>Extract text and tables from PDF files...</description>
    </skill>
  </available_skills>
  ```

### Tool Layer

- **`load_skill`**: A built-in tool exposed to the model (gated by `assistant.skillIds`). Named to mirror `read_memory` (memory 'tool' mode). Parameter `{ name: string }` (required). Returns XML:
  ```xml
  <skill name="pdf-processing">
    <instructions>
      [SKILL.md Markdown body]
    </instructions>
    <files>
      <file path="scripts/extract.py" size="2150"/>
      <file path="references/api-docs.md" size="8602"/>
    </files>
  </skill>
  ```
  Skills with no auxiliary files omit the `<files>` element. Progressive disclosure level 2: the model sees the file tree only after choosing to load the skill.
- **`read_skill_file`**: A built-in tool exposed to the model (gated by same `assistant.skillIds` as `load_skill`). Parameters `{ name: string, path: string }` (both required). Returns the content of an auxiliary file within a skill directory. Security boundaries: rejects paths containing `..`, absolute paths, and backslashes (forward-slash relative paths only). Binary files → error message. Content capped at 64 KB with `[truncated]` suffix. Progressive disclosure level 3: the model reads specific files on demand after seeing the listing in `load_skill`.

### Assistant Binding

- **`assistant.skillIds`**: `List<String>` on the `Assistant` model, stored in SQLite as JSON (`skillIdsJson` TEXT column, same pattern as `localToolIdsJson`). Only skills in this list are injected into the assistant's `<available_skills>` and have their `load_skill`/`read_skill_file` tool definitions exposed.

### Backup Integration

- `skills/` directory is always included in backup ZIPs — NOT gated by `includeFiles`. Rationale: skill files are small (pure text) and fundamental to assistant behavior. Incremental backup filters by mtime via existing `_addDirectoryToZip(since:)`.
- Restore: `_extractZipSync` decompresses `skills/` entries, preserving mtime from ZIP entry `lastModTime`. `SkillManager` discovers imported skills on next `listSkills()`.

### Relationship to Existing Concepts

- **Skill vs InstructionInjection**: Both provide instructions to the model. **InstructionInjection** follows `memory 'injection'` mode: full prompt is injected into every system message regardless of relevance. **Skill** follows `memory 'tool'` mode: only metadata (name/description) is injected; the model must choose to call `load_skill` to read the full body. This is the key structural distinction — `InstructionInjection : injection mode :: Skill : tool mode`.
- **Skill vs WorldBook**: **WorldBook** entries are triggered by keyword/regex matching against conversation context and injected at specific positions (after system prompt, top of chat, bottom of chat, at depth). **Skill** has no keyword triggering — the model decides based on the `<available_skills>` descriptions.
- **Skill vs LocalTool/MCP**: **LocalTool** and **MCP** are executable tools: model calls them → something happens (read clipboard, execute code). **Skill**'s `load_skill` is a "knowledge tool": model calls it → receives instruction text → nothing executes. Same tool dispatch pathway, different semantics.

## Time Injection (Cache-Aware)

- **Time Injection**: A per-assistant feature (`Assistant.enableTimeInjection`, default off) that appends a timestamp to every user message in the API payload at build time. Ephemeral — never persisted to DB, never shown in chat UI. The timestamp is derived from the message's immutable `ChatMessage.timestamp`, so historical messages produce byte-identical output across requests on a device with a stable timezone, preserving the LLM provider's prompt cache prefix. Note: the timestamp uses device-local time without a UTC offset; if the device timezone changes, historical timestamps resolve to different local components and the cache prefix will invalidate.
- **`<time-note>`**: A hardcoded English model instruction appended at the very end of the assembled system message (after all other injections). Tells the model that timestamps follow each user message. Static content — does not invalidate cache.
- **Timestamp format**: `\n\n(Mon 25-07-26 14:03:22)` — abbreviated English day name, compact date with hyphens, local time (device timezone, no UTC offset). Appended after all other user message processing (markers, doc extraction, OCR, regex transforms).
- **Message template bypass**: When enabled, `applyMessageTemplate()` is skipped entirely. The two features are mutually exclusive by design — the template's `{{ time }}`/`{{ date }}` variables use volatile `DateTime.now()` and would defeat the cache goal.
- **Preset messages**: Excluded (`isPreset` check). Canned conversation starters are structural scaffolding, not real temporal events.
- **Volatile variable warning**: On toggle-on, a one-time dialog scans `assistant.systemPrompt` for `{cur_date}`, `{cur_time}`, `{cur_datetime}` and `assistant.memoryRecordPrompt` for `{current_hour}`, `{current_date}`, `{current_datetime}`. Lists only variables actually present. Skipped entirely if none found. Informational only — no enforcement.
- **Delta** (deferred): A "since last message" duration suffix was considered but deferred. If added later, it would also be derived from stored timestamps (cache-stable).

### Example Dialogue

> **Dev:** "A user pasted a long workflow prompt into InstructionInjection expecting the model to use it only when working on that specific task. Should this be a Skill instead?"
> **Domain expert:** "Correct. InstructionInjection always injects into every system prompt — it's `memory 'injection'` mode. The model gets that prompt unconditionally, even for unrelated queries. Skill only exposes its name and description in `<available_skills>`; the model reads the full body only when it calls `load_skill`. This way the instruction stays out of context until it's actually needed."

## Custom Request Layers (Headers & Body)

- **4-layer merge order** (last wins on key collision):
  1. `providerDefaultHeaders` — hardcoded per provider type (e.g. OpenRouter `X-Title`)
  2. **Provider-level** — `ProviderConfig.customHeaders` / `.customBody` (applies to all models under the provider)
  3. **Model-level** — `ProviderConfig.modelOverrides[modelId]['headers']` / `['body']` (per-model override)
  4. **Assistant-level** — `Assistant.customHeaders` / `.customBody` (per-assistant, passed as `extraHeaders`/`extraBody`)
- **Merge semantics**: Shallow (`Map.addAll`). A later layer replaces the entire value for a colliding top-level key. Deep/nested merge is NOT supported (upstream issue Chevey339/kelivo#804).
- **Data format**: `List<Map<String, String>>` — headers use `{name, value}` keys; body uses `{key, value}` keys. Consistent across all layers.
- **No guardrails**: Users may set any header key (including `Authorization`, `Content-Type`). Power-user responsibility.

## Storage Space Management (Enhancements)

- **占用空间 (occupied space)**: The logical file size in bytes (`StorageFileEntry.bytes`), as reported by the OS. NOT disk block allocation. "Sort by occupied space" and "sort by size" are the same single sort key.
- **引用计数 (reference count)**: The number of chat messages whose content references a file's path (same extraction logic as `_cleanupOrphanUploads` in `chat_service.dart`). refCount=0 means "orphaned" — consistent with existing orphan-cleanup semantics.
- **Draft exclusion**: Unsent input-draft / pending-input-bar references do NOT count toward refCount. The persisted draft (`chat_draft_v1`) is always in sync with the in-memory input bar, so it is the single source for the deletion guardrail below.
- **Deletion guardrail**: When deleting a refCount=0 file, the delete path cross-checks the persisted draft. If the file is still referenced by the unsent draft, the confirm dialog is enriched with a warning but deletion is still allowed (warn-and-allow, not block). Rationale: a stale/abandoned draft should not trap the user; the user retains final authority.
- **引用计数与反向定位同源**: refCount and reverse-locate are derived from ONE scan that builds `path → List<location>`, where each location records `conversationId`, `conversationTitle`, `messageId`, and a short message preview. `refCount = locations.length`. Never scan twice.
- **引用计数计算时机 (triggered-on-demand)**: The refCount scan is a CPU-bound synchronous full-message pass (same shape as the stats page read, which stutters the UI ~0.5s). It is NOT run on page load. It is triggered on demand by either (a) turning on the "只看无引用" orphan filter, or (b) tapping a file to view its references. A loading indicator covers the ~0.5s. The result is cached for the session and invalidated on manual refresh and after any deletion. Rationale: refCount is a secondary cleanup feature; the common path (glance at usage / clear cache) must stay fast. Size (`StorageFileEntry.bytes`), by contrast, is cheap (from the file stat) and is always available on load — so size is shown eagerly while refCount is on-demand.
- **图片占用空间显示**: Image tiles in the storage grid show file size as an always-visible bottom gradient overlay (mirrors the chat input bar pattern, `chat_input_bar.dart:1906`). Size is eager (cheap, from the file stat). The refCount badge is a SEPARATE corner badge that appears only after the on-demand scan — size (bottom, eager) and refCount (corner, on-demand) never conflict. File rows already show size in their subtitle; they only gain a trailing refCount label after the scan.
- **排序 (sorting)**: A single sort dimension toggle — [按大小 | 按时间] — in the `_UploadManager` actions row, applying uniformly to the image grid and the file list. Sorting is client-side over the already-loaded `_entries` (which carry `bytes` and `modifiedAt`); no re-fetch. Default is 按时间 desc (preserves current behavior). Each mode defaults descending (largest/newest first — the cleanup-useful order); tapping the active segment flips asc↔desc with an arrow indicator. "Sort by occupied space" and "sort by size" are the SAME 按大小 mode. The segment control is a page-private widget (no shared segmented control exists in the repo); per explicit request it carries a comment noting it is intentionally page-local and should be extracted to `shared/widgets/` only if reused elsewhere.
- **反向定位 (reverse locate)**: Cross-conversation. Mirrors the global full-text search click-to-locate UX (result list grouped by conversation title + message preview; tap to jump). Reuses `HomePageController.openGlobalSearchResult({conversationId, messageId})` (`home_page_controller.dart:629`), which switches conversation, scrolls to the message, and flash-highlights it via the spotlight mechanism. NOT restricted to the current conversation — the intent is "which chats use this file?".
- **Cross-tab wiring (stopgap)**: `HomePageController` is page-private (built in `_HomePageState.initState`, entangled with a page-owned `ChatAutoFollowScrollController`), not in the root Provider tree. The Storage page reaches it via a new singleton payload bus `MessageLocateBus` (mirrors `DesktopSettingsNavigationBus`), carrying `{conversationId, messageId}`. Desktop: `DesktopHomePage` also listens and switches to the Chat tab. Mobile: fire the bus then `Navigator.pop` back to the alive chat route. This is a DOCUMENTED STOPGAP — the long-term direction is promoting `HomePageController` to a root provider and deleting the bus. See `docs/adr/0005-storage-reverse-locate-bus-stopgap.md`.

### Safety boundaries & edge cases

- **孤儿检测限定 `upload/` (DATA-SAFETY)**: Message content has TWO coexisting local-file reference syntaxes: the marker syntax `[image:]`/`[file:]` (parsed by `_extractAttachmentPaths`) AND standard Markdown `![alt](path)` (written by `MarkdownMediaSanitizer` for LLM inline images under `images/`, plus assistant images referenced by assistant config, plus theoretically user-authored Markdown links). The extractor sees ONLY markers. Therefore orphan detection + the "只看无引用" filter + orphan bulk-delete are restricted to **`upload/` files only** (matching the proven `_cleanupOrphanUploads` scope). `images/` files are EXCLUDED from orphan deletion; their refCount is best-effort informational only (under-counts Markdown/config refs) and must never drive a delete decision in the UI. Markdown-reference parsing is a documented DEFERRED task. See `docs/adr/0006-refcount-marker-only-upload-scope.md`.
- **路径规范化 (must-get-right)**: The reference scan MUST reuse `_cleanupOrphanUploads`'s `canon()` (normalize + Windows lowercase) and apply `SandboxPathResolver.fix()` to message paths, comparing against canonicalized on-disk paths. Otherwise iOS sandbox-container path changes across app updates and Windows case-insensitivity produce mass false orphans.
- **版本计数**: refCount counts ALL message versions (not just the visible/selected version), matching `_cleanupOrphanUploads` which iterates every message. This keeps "refCount=0 ⟺ the existing cleanup would delete it" true. Consequence: reverse-locate navigates via collapsed (visible) messages, so locating a reference that exists only in a hidden version switches to the conversation but may not scroll precisely (best-effort; `scrollToMessageId` returns early if the target isn't among collapsed messages).
- **删除已引用文件的警告**: The delete-confirm dialog is enriched when any selected file has refCount > 0 (and counts are computed): it states how many selected files are referenced by messages and that deleting breaks their display. Mirrors the draft guardrail (warn-and-allow).
- **扫描须让出 isolate**: The on-demand scan is CPU-bound; a tight synchronous loop would freeze the UI AND freeze the loading spinner. The scan loop must yield periodically (e.g. `await` every ~200 messages) so the spinner animates and the UI stays responsive. A guard flag prevents concurrent scans from rapid filter toggles.
- **Trivially handled**: sort tie-break by name (deterministic); refCount dedupes within a message (count = number of messages, not occurrences); missing `upload/`/`images/` dirs handled as today; a draft-only file shows refCount 0 but the delete guardrail warns (no separate "草稿" badge — YAGNI).

### Flagged Ambiguities

- "skill" was used interchangeably to mean both "a set of instructions loaded from disk" and "an individual step in a model's reasoning process" — resolved: the former is **Skill** (capitalized, bounded in the codebase), the latter falls under general LLM domain language and is not part of Cuplivo's domain model.
