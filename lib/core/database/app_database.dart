import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../utils/app_directories.dart';

part 'app_database.g.dart';

@TableIndex(name: 'idx_conversations_updated_at', columns: {#updatedAt})
@TableIndex(name: 'idx_conversations_assistant', columns: {#assistantId})
class ConversationRows extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  TextColumn get assistantId => text().nullable()();
  IntColumn get truncateIndex => integer().withDefault(const Constant(-1))();
  TextColumn get versionSelectionsJson =>
      text().withDefault(const Constant('{}'))();
  TextColumn get summary => text().nullable()();
  IntColumn get lastSummarizedMessageCount =>
      integer().withDefault(const Constant(0))();
  TextColumn get chatSuggestionsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get parentConversationId => text().nullable()();

  /// 'normal' | 'group' — group public transcripts use kind=group.
  TextColumn get conversationKind =>
      text().withDefault(const Constant('normal'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@TableIndex(
  name: 'idx_messages_conversation_order',
  columns: {#conversationId, #messageOrder},
)
@TableIndex(
  name: 'idx_messages_conversation_timestamp',
  columns: {#conversationId, #timestamp},
)
@TableIndex(name: 'idx_messages_group', columns: {#groupId})
@TableIndex(name: 'idx_messages_subgroup', columns: {#subgroupId})
class MessageRows extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get role => text()();
  TextColumn get content => text()();
  DateTimeColumn get timestamp => dateTime()();
  TextColumn get modelId => text().nullable()();
  TextColumn get providerId => text().nullable()();
  IntColumn get totalTokens => integer().nullable()();
  BoolColumn get isStreaming => boolean().withDefault(const Constant(false))();
  TextColumn get reasoningText => text().nullable()();
  DateTimeColumn get reasoningStartAt => dateTime().nullable()();
  DateTimeColumn get reasoningFinishedAt => dateTime().nullable()();
  TextColumn get translation => text().nullable()();
  TextColumn get reasoningSegmentsJson => text().nullable()();
  TextColumn get groupId => text().nullable()();
  TextColumn get subgroupId => text().nullable()();
  IntColumn get version => integer().withDefault(const Constant(0))();
  IntColumn get promptTokens => integer().nullable()();
  IntColumn get completionTokens => integer().nullable()();
  IntColumn get cachedTokens => integer().nullable()();
  IntColumn get durationMs => integer().nullable()();
  IntColumn get messageOrder => integer()();
  BoolColumn get isPreset => boolean().withDefault(const Constant(false))();

  /// Speaker assistant id for group chats; null for user messages / 1:1.
  TextColumn get speakerAssistantId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AssistantRows extends Table {
  //--- Identifier & Display ---
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get avatar => text().nullable()();
  BoolColumn get useAssistantAvatar =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get useAssistantName =>
      boolean().withDefault(const Constant(false))();
  TextColumn get background => text().nullable()();

  // --- Model Selection ---
  TextColumn get chatModelProvider => text().nullable()();
  TextColumn get chatModelId => text().nullable()();

  // --- Request Params ---
  RealColumn get temperature => real().nullable()();
  RealColumn get topP => real().nullable()();
  IntColumn get contextMessageSize =>
      integer().withDefault(const Constant(64))();
  BoolColumn get limitContextMessages =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get streamOutput => boolean().withDefault(const Constant(true))();
  IntColumn get thinkingBudget => integer().nullable()();
  IntColumn get maxTokens => integer().nullable()();
  TextColumn get customHeadersJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get customBodyJson => text().withDefault(const Constant('[]'))();

  // --- Messages ---
  TextColumn get systemPrompt => text().withDefault(const Constant(''))();
  TextColumn get messageTemplate =>
      text().withDefault(const Constant('{{ message }}'))();
  TextColumn get presetMessagesJson =>
      text().withDefault(const Constant('[]'))();

  // --- Extended Functionality ---
  BoolColumn get searchEnabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get mcpServerIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get localToolIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get skillIdsJson => text().withDefault(const Constant('[]'))();
  TextColumn get regexRulesJson => text().withDefault(const Constant('[]'))();

  // --- Proactive Care ("Ta的来信") ---
  BoolColumn get enableProactiveCare =>
      boolean().withDefault(const Constant(false))();
  DateTimeColumn get proactiveCareNextMessageAt => dateTime().nullable()();
  TextColumn get proactiveCarePrompt =>
      text().withDefault(const Constant(''))();
  TextColumn get proactiveCareDecisionPrompt =>
      text().withDefault(const Constant(''))();

  // --- Memory ---
  BoolColumn get enableMemory => boolean().withDefault(const Constant(false))();
  TextColumn get memoryMode =>
      text().withDefault(const Constant('injection'))();
  BoolColumn get enableRecentChatsReference =>
      boolean().withDefault(const Constant(false))();
  IntColumn get recentChatsSummaryMessageCount =>
      integer().withDefault(const Constant(5))();
  TextColumn get memoryRecordPrompt => text().withDefault(const Constant(''))();

  // --- File Processing ---
  TextColumn get docxMode => text().withDefault(const Constant('extract'))();
  TextColumn get pdfMode => text().withDefault(const Constant('extract'))();
  TextColumn get otherOfficeMode =>
      text().withDefault(const Constant('direct'))();

  // --- Time Injection ---
  BoolColumn get enableTimeInjection =>
      boolean().withDefault(const Constant(false))();

  // --- Handoff / Delegation ---
  BoolColumn get discoverable => boolean().withDefault(const Constant(false))();
  TextColumn get handoffId => text().nullable()();
  TextColumn get handoffDescription => text().nullable()();

  // --- Sort & Timestamp ---
  IntColumn get sortOrder => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ConversationMcpServerRows extends Table {
  TextColumn get conversationId =>
      text().references(ConversationRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get serverId => text()();
  IntColumn get ordinal => integer()();

  @override
  Set<Column<Object>> get primaryKey => {conversationId, serverId};
}

class ToolEventRows extends Table {
  TextColumn get messageId =>
      text().references(MessageRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get eventsJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {messageId};
}

class GeminiThoughtSignatureRows extends Table {
  TextColumn get messageId =>
      text().references(MessageRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get signature => text()();

  @override
  Set<Column<Object>> get primaryKey => {messageId};
}

class CacheRows extends Table {
  TextColumn get type => text()(); // e.g., 'ocr'
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {type, key};
}

class ChatStorageMetaRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Recoverable payloads for locally-deleted entities.
///
/// Each row = one top-level entity bundle. For a conversation, the bundle
/// nests its messages + toolEvents + geminiSigs + MCP server links. For a
/// message, the bundle nests its toolEvents/sigs.
///
/// NOT backed up — excluded structurally (backup export never queries this
/// table). Subject to a user-configurable byte cap (default 10 MB); oldest
/// rows are evicted when over cap, never the current write batch.
class DeletedRecordRows extends Table {
  TextColumn get id => text()();
  TextColumn get type =>
      text()(); // conversation|message|assistant|worldBook|quickPhrase|mcpServer|memory
  TextColumn get recoveryJson => text()();
  IntColumn get size => integer()(); // bytes(utf8(recoveryJson)) + 256
  DateTimeColumn get createdAt => dateTime()(); // deletion time
  TextColumn get batchId =>
      text()(); // shared by rows from the same delete operation

  @override
  Set<Column<Object>> get primaryKey => {id, type};
}

/// Id-only tombstones for sync/backup, with no payload.
///
/// `origin='local'` rows are written on every local delete (dual-write with
/// [DeletedRecordRows]) and are the source of `deleted.json`. `origin='remote'`
/// rows are written when a sync peer or backup's `deleted.json` declares an id
/// that still exists locally; the UI marks these as "远端已删除".
///
/// Unified 5000-row FIFO by [deletedAt], regardless of origin. The `origin`
/// column prevents sync echo: `deleted.json` is generated from
/// `origin='local'` rows only.
class DeletionMarkerRows extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()();
  TextColumn get origin => text()(); // 'local' | 'remote'
  DateTimeColumn get deletedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id, type, origin};
}

// ===== Multi-assistant group chat (schema v13) =====
// Layered model: the public transcript lives in ConversationRows
// (conversation_kind='group') + MessageRows.speakerAssistantId; GroupChatRows
// holds metadata + per-round runtime state; GroupChatMemberRows is the M:N
// membership join (same shape as ConversationMcpServerRows); DirectorMessageRows
// is the Director's private session — a second stream that must NEVER be read
// by public-transcript consumers. See docs/adr/0015 and CONTEXT.md.
// Sync rule: any new group-related table must be wired into clearAllData
// (child-before-parent FK order), _exportChatsToFile and _restoreFromBackupFile
// in the same change.
@TableIndex(name: 'idx_group_chats_updated_at', columns: {#updatedAt})
class GroupChatRows extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get avatar => text().nullable()();
  TextColumn get conversationId => text().unique().references(
    ConversationRows,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get directorModelProvider => text().nullable()();
  TextColumn get directorModelId => text().nullable()();
  TextColumn get directorSystemPrompt =>
      text().withDefault(const Constant(''))();
  IntColumn get maxAssistantMessagesPerRound =>
      integer().withDefault(const Constant(3))();
  TextColumn get assistantDetailInjectionMode =>
      text().withDefault(const Constant('endOfEveryUserMessage'))();
  IntColumn get assistantDetailInjectionN =>
      integer().withDefault(const Constant(5))();
  TextColumn get pendingCapAssistantMessageId => text().nullable()();
  IntColumn get assistantMessagesThisRound =>
      integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class GroupChatMemberRows extends Table {
  TextColumn get groupChatId =>
      text().references(GroupChatRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get memberKey => text()();
  TextColumn get assistantId => text().nullable()();
  IntColumn get sortOrder => integer()();

  @override
  Set<Column<Object>> get primaryKey => {groupChatId, memberKey};
}

@TableIndex(
  name: 'idx_director_messages_group_order',
  columns: {#groupChatId, #messageOrder},
)
class DirectorMessageRows extends Table {
  TextColumn get id => text()();
  TextColumn get groupChatId =>
      text().references(GroupChatRows, #id, onDelete: KeyAction.cascade)();
  TextColumn get role => text()();
  TextColumn get content => text()();
  IntColumn get messageOrder => integer()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get metaJson => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    ConversationRows,
    MessageRows,
    AssistantRows,
    ConversationMcpServerRows,
    ToolEventRows,
    GeminiThoughtSignatureRows,
    CacheRows,
    ChatStorageMetaRows,
    DeletedRecordRows,
    DeletionMarkerRows,
    GroupChatRows,
    GroupChatMemberRows,
    DirectorMessageRows,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  static const databaseFileName = 'kelivo.sqlite';

  factory AppDatabase.open({File? file}) {
    final databaseFile = file;
    if (databaseFile != null) {
      return AppDatabase(_openExecutor(databaseFile));
    }
    return AppDatabase(
      LazyDatabase(() async {
        final dir = await AppDirectories.getAppDataDirectory();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return _openExecutor(File('${dir.path}/$databaseFileName'));
      }),
    );
  }

  static QueryExecutor _openExecutor(File file) {
    return NativeDatabase.createInBackground(
      file,
      setup: (database) {
        database.execute('PRAGMA journal_mode = WAL;');
        database.execute('PRAGMA foreign_keys = ON;');
        database.execute('PRAGMA busy_timeout = 5000;');
      },
      readPool: 1,
    );
  }

  @override
  // Migrations follow the original per-version pattern only — no runtime
  // self-heal. A locally corrupted dev DB is repaired by reinstalling, not
  // by healing schema on every open.
  int get schemaVersion => 13;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON;');
      await customStatement('PRAGMA busy_timeout = 5000;');
    },
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.createTable(assistantRows);
        await migrator.createTable(cacheRows);
      }
      if (from < 3) {
        try {
          await migrator.addColumn(assistantRows, assistantRows.memoryMode);
        } catch (_) {
          // The column may already exist (due to migration replay or partial failure retry); simply ignore it.
        }
      }
      if (from < 4) {
        try {
          await migrator.addColumn(messageRows, messageRows.subgroupId);
        } catch (_) {
          // The column may already exist (due to migration replay or partial failure retry); simply ignore it.
        }
      }
      if (from < 5) {
        try {
          await migrator.addColumn(assistantRows, assistantRows.docxMode);
        } catch (_) {}
        try {
          await migrator.addColumn(assistantRows, assistantRows.pdfMode);
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.otherOfficeMode,
          );
        } catch (_) {}
      }
      if (from < 6) {
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.enableProactiveCare,
          );
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.proactiveCareNextMessageAt,
          );
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.proactiveCarePrompt,
          );
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.proactiveCareDecisionPrompt,
          );
        } catch (_) {}
      }
      if (from < 7) {
        try {
          await migrator.addColumn(assistantRows, assistantRows.skillIdsJson);
        } catch (_) {}
        await customStatement(
          "UPDATE assistant_rows SET skill_ids_json = '[]' WHERE skill_ids_json IS NULL",
        );
      }
      if (from < 8) {
        try {
          await migrator.addColumn(messageRows, messageRows.isPreset);
        } catch (_) {}
      }
      if (from < 9) {
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.enableTimeInjection,
          );
        } catch (_) {}
      }
      if (from < 11) {
        try {
          await migrator.createTable(deletedRecordRows);
          await migrator.createTable(deletionMarkerRows);
        } catch (_) {
          // Tables may already exist (migration replay / partial retry).
        }
      }
      if (from < 12) {
        try {
          await migrator.addColumn(
            conversationRows,
            conversationRows.parentConversationId,
          );
        } catch (_) {}
        try {
          await migrator.addColumn(assistantRows, assistantRows.discoverable);
        } catch (_) {}
        try {
          await migrator.addColumn(assistantRows, assistantRows.handoffId);
        } catch (_) {}
        try {
          await migrator.addColumn(
            assistantRows,
            assistantRows.handoffDescription,
          );
        } catch (_) {}
      }
      if (from < 13) {
        try {
          await migrator.createTable(groupChatRows);
        } catch (_) {
          // table may already exist on migration replay
        }
        try {
          await migrator.createTable(groupChatMemberRows);
        } catch (_) {}
        try {
          await migrator.createTable(directorMessageRows);
        } catch (_) {}
        try {
          await migrator.addColumn(
            conversationRows,
            conversationRows.conversationKind,
          );
        } catch (_) {
          // column may already exist on migration replay
        }
        try {
          await migrator.addColumn(messageRows, messageRows.speakerAssistantId);
        } catch (_) {
          // column may already exist on migration replay
        }
        await customStatement(
          "UPDATE conversation_rows SET conversation_kind = 'normal' "
          "WHERE conversation_kind IS NULL OR conversation_kind = ''",
        );
      }
    },
  );
}
