# ADR-0028: GenerationEngine — the Unified Conversational Pipeline

The `GenerationEngine` (formerly `HeadlessGenerationService`) becomes the single
deep module for every tool-bearing conversational generation path, replacing the
three drifting parallel chunk loops (page `chat_actions`, group-chat member
executor, subagent headless run). All generation is organized into three layers
by tool capability.

## Problem

Three independent implementations of the same "consume chunk stream → state +
persistence" loop existed and drifted apart (the group-chat executor literally
carried a `SOURCE PARITY: chat_actions.dart` comment):

1. **Page path** (`chat_actions.dart` + `StreamController`): the full pipeline —
   multi-round reasoning segments/splits, tool events, Gemini thought
   signatures, inline image sanitization, smooth pacing, throttled persistence.
2. **Group-chat member executor** (`group_chat_stream_executor.dart`): a
   source-parity fork of the page loop (no pacing, incremental drift).
3. **Headless run** (`HeadlessGenerationService._run`): a degraded functional
   subset — single reasoning buffer, single content split, no regex transform,
   no per-chunk persistence (crash loses everything), no Gemini signatures,
   no image sanitization.

Issue #254 (multi-round tool-call reasoning, tool/content ordering, assistant
avatar/nickname) was one symptom of the third implementation being a subset of
the first.

## Decision: three-layer generation architecture, engine owns the conversational pipeline

### Layer ① No-tool (无工具层)

A thin shared text-stream collector in `lib/core/services/`:
`sendMessageStream` → accumulate `chunk.content` → return/callback, with
parameters passed through. Consumers: OCR, translation, translate page,
ProactiveCare care reply. Non-stream consumers (chat suggestions, title
generation) stay on `generateText`, which is already shared.

### Layer ② Director (导演层)

The group-chat Director's protocol loop stays its own implementation.
Excluded because its semantics are inverted relative to a chat pipeline: the
first valid tool call is final (stream cancelled immediately), tool results are
neutral `{"ok":true}`, and nothing is persisted (the session is rebuilt from
the public transcript). The engine's contract is "persist an assistant message
row"; forcing the Director through it would require a no-persist mode and
inverted completion semantics, widening the engine interface for a single
non-conversational consumer.

### Layer ③ Full-tool engine (全工具层) — GenerationEngine

A **Round/Slot** model, aligned with the data model that already exists
(`roundGroupId`, `subgroupId` cards):

- **Round (生成轮)**: one `startRound({conversationId, slots})` call. A
  transient in-memory execution token — never persisted; the message rows carry
  the persisted identity (`groupId`/`version`/`subgroupId`). Single AI = 1-slot
  Round; Multi-AI = N parallel slots in one Round; subagent = 1-slot Round in
  the child conversation; group-chat member turns = 1-slot Rounds sequenced by
  the orchestrator. `regenerate` = a new Round over the same `groupId` with a
  new `version`. Per-conversation Rounds are sequential in practice (the UI
  gates sends); the engine does not enforce it.
- **Slot (槽位)**: one generation target — "stream into one pre-created
  assistant placeholder message row". The caller creates the placeholder
  (page: version/group/subgroup/speaker control; subagent server: plain
  placeholder) and passes `assistantMessageId`; the engine never creates
  message rows. Each slot carries: stream params, its own live state
  (`StreamingContentNotifier`, status, `lastStep`, `toolCallCount`, accumulated
  text, completion future), and its own CancelToken (`requestId = messageId` —
  required for N parallel slots in one conversation).

The engine absorbs the full page pipeline machinery:

- Multi-round reasoning segments/splits (the state machine from
  `stream_controller`: finish segment on tool start, new segment after tools,
  one content split per thinking→content episode) — this is the issue #254
  fix.
- Per-chunk throttled persistence: content per chunk, reasoning on a 500 ms
  flush cadence, tool events immediately, final `isStreaming: false` write at
  finish.
- Gemini thought signature capture, inline base64 image sanitization, and the
  assistant streaming regex transform (previously missing in headless — a real
  behavior gap fixed).
- Engine-owned per-slot `StreamingContentNotifier` + the 50 ms smooth-pacing
  ramp (pure state machine, no-ops when nobody is registered). Every path
  renders identically.

### Excluded from the engine (in addition to the Director)

- **ProactiveCare decision pipeline** (`decideNextCareTime`): single-decision
  tool extraction with no message row — same exclusion shape as the Director.
- **ProactiveCare care reply**: layer-① collector + manual
  `appendAssistantReply`. It must stay silent, and the killed-process isolate
  has no provider stack, so routing it through the engine would create a second
  parallel implementation, not a unification.

## Rejected alternatives

1. **Extend headless in place** (mirror the segment/split state machine inside
   `_run`). Rejected: deepens the duplication the issue exposed; the engine
   stays a functional subset that must be kept in sync manually.
2. **Extract only the pure state machine** into a shared helper used by both
   `stream_controller` and headless. Rejected: the friction is not one helper
   — it is three parallel loop+persistence implementations. A shared helper
   would leave the page/group/subagent loops still duplicating the rest.
3. **One engine with mode switches** (no-persist mode for Director/ProactiveCare
   decision, no-tool mode for OCR/translation). Rejected: mode flags widen the
   interface with conditional complexity — the opposite of a deep module. The
   three-layer split is the mode-free expression of the same idea.
4. **Job keyed by conversationId with a multi-AI special case**. Rejected: the
   Round/Slot model makes Multi-AI the natural case (N slots) and single AI the
   degenerate case (1 slot) — no engine-level special-casing.

## Consequences

- Reverses two ADR-0026 statements: the one-shot DB write (now per-chunk
  throttled — subagents gain crash recovery; a crash loses at most one cadence
  window) and the deferral of 方向 B to cuplivo v3 (now executed in v2.8).
- Deletes `headless_generation_service.dart` (replaced by
  `lib/core/services/generation_engine.dart`), and in later stages
  `group_chat_stream_executor.dart` and the page `StreamController`/chunk loop.
- **Compatibility boundary (reasoning payload decoding)**: the payload
  serializer moved from a hand-rolled JSON encoder to `dart:convert`. The old
  encoder left raw control characters (0x00–0x1F) unescaped, so legacy
  `reasoningSegmentsJson` rows containing them are rejected by `jsonDecode`.
  All decode sites are try/catch-wrapped, and the `reasoningText` column is
  independent, so the impact is graceful: affected legacy rows fall back to
  the single-segment thinking display instead of the interleaved rendering.
  Accepted; no migration.
- The subagent behavior changes: error policy becomes the page policy (keep
  partial content; error text only when empty); the child conversation renders
  with smooth pacing; content survives crashes.
- The wait-mode handoff API shape is preserved: the tool-handler layer still
  awaits a completion future (`waitFor(conversationId)`), the panel still binds
  to per-job state (now per-slot), cascading cancel still walks
  `parentConversationId`.
- Issue #254's third item (assistant avatar/nickname) is completed by the
  conversation-level avatar/name resolution (child conversations render their
  target assistant's identity). The forward-navigation chip remains
  v1-`kelivo_handoff`-only by design: a wait-mode tool event's content is the
  child's full output, and scanning it for a conversation UUID would navigate
  to a wrong conversation — the 子代理面板's 查看子对话 covers wait-mode
  navigation (see CONTEXT.md Forward bar).

## Migration (staged, each stage keeps the full local test suite green)

1. Engine + subagent migration (this ADR's first landing): new engine, subagent
   path moves onto it, issue #254 closed.
2. Group-chat member executor moves onto the engine; the parity file is
   deleted.
3. Page path moves onto the engine (Multi-AI = N-slot Rounds); the page
   `StreamController` and the `chat_actions` chunk loop are deleted;
   `MessageGenerationService`/`GenerationController` remain as the prep
   adapter layer.
4. Layer-① collector extraction: OCR, translation, translate page, ProactiveCare
   care reply.
