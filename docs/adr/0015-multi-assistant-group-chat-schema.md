# Multi-Assistant Group Chat: Three New Tables + Two Columns (schema v13)

Group chat persistence uses 3 new tables (`GroupChatRows`, `GroupChatMemberRows`, `DirectorMessageRows`) plus 2 new columns (`conversation_kind`, `speaker_assistant_id`) on existing tables, instead of the MultiAI-style "just add a column" approach. MultiAI's `subgroupId` was sufficient because it added an attribute to an existing entity (the message); group chat introduces three entity shapes that existing tables cannot carry.

## Considered Options

1. **Columns-only (extend ConversationRows/MessageRows).** Rejected: membership is a real M:N relationship (repo pattern = join table, cf. `ConversationMcpServerRows`); 10+ group-only config/runtime columns would pollute the conversation table; a JSON member list is off-pattern for entity relationships in this repo.

2. **Director session in MessageRows with a marker column.** Rejected: it is a second, unbounded append-only stream; every public-stream consumer (context building, memory, summary, backup, trash restore, version collapse) would need to filter it — a large regression surface. `getMessages` stays clean by construction instead.

3. **Director session as a JSON blob on the group row.** Rejected: each turn appends → full-log JSON rewrite per turn (O(n²) write amplification over the chat's lifetime), and no typed queries.

4. **Typed tables per entity shape (chosen).** `GroupChatRows` (metadata + per-round runtime state, FK cascade from `ConversationRows`), `GroupChatMemberRows` (M:N join, same shape as `ConversationMcpServerRows`), `DirectorMessageRows` (append-only private stream with `(groupChatId, messageOrder)` index). Two attribute columns on existing entities (`conversation_kind`, `speaker_assistant_id`) follow the MultiAI column precedent where the shape is genuinely "an attribute of an existing entity".

## Consequences

- Schema v12 → v13: migration creates 3 tables + 2 columns; the migration block follows the existing per-version `onUpgrade` pattern.
- Group chat is a first-class recoverable entity (`DeletionEntityType.groupChat`) with its own trash bundle (group + members + director session), independent of the conversation trash record.
- Backup chats.json is bumped to v2 and gains 3 sections (`groupChats` / `groupMembers` / `directorMessages`); v1 backups restore without them (missing keys default to empty).
- Sync rule: any future group-related table must be wired into `clearAllData` (child-before-parent FK order), backup export, and backup restore in the same change.
