import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Reproduces: user_version already advanced but handoff columns missing.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cuplivo_heal_');
    dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('heal adds missing discoverable before assistant insert', () async {
    // Create a minimal pre-handoff assistant_rows (no discoverable/handoff_*).
    final raw = sqlite.sqlite3.open(dbFile.path);
    raw.execute('PRAGMA user_version = 13;');
    raw.execute('''
CREATE TABLE assistant_rows (
  id TEXT NOT NULL PRIMARY KEY,
  name TEXT NOT NULL,
  avatar TEXT NULL,
  use_assistant_avatar INTEGER NOT NULL DEFAULT 0,
  use_assistant_name INTEGER NOT NULL DEFAULT 0,
  background TEXT NULL,
  chat_model_provider TEXT NULL,
  chat_model_id TEXT NULL,
  temperature REAL NULL,
  top_p REAL NULL,
  context_message_size INTEGER NOT NULL DEFAULT 64,
  limit_context_messages INTEGER NOT NULL DEFAULT 1,
  stream_output INTEGER NOT NULL DEFAULT 1,
  thinking_budget INTEGER NULL,
  max_tokens INTEGER NULL,
  custom_headers_json TEXT NOT NULL DEFAULT '[]',
  custom_body_json TEXT NOT NULL DEFAULT '[]',
  system_prompt TEXT NOT NULL DEFAULT '',
  message_template TEXT NOT NULL DEFAULT '{{ message }}',
  preset_messages_json TEXT NOT NULL DEFAULT '[]',
  search_enabled INTEGER NOT NULL DEFAULT 0,
  mcp_server_ids_json TEXT NOT NULL DEFAULT '[]',
  local_tool_ids_json TEXT NOT NULL DEFAULT '[]',
  skill_ids_json TEXT NOT NULL DEFAULT '[]',
  regex_rules_json TEXT NOT NULL DEFAULT '[]',
  enable_proactive_care INTEGER NOT NULL DEFAULT 0,
  proactive_care_next_message_at INTEGER NULL,
  proactive_care_prompt TEXT NOT NULL DEFAULT '',
  proactive_care_decision_prompt TEXT NOT NULL DEFAULT '',
  enable_memory INTEGER NOT NULL DEFAULT 0,
  memory_mode TEXT NOT NULL DEFAULT 'injection',
  enable_recent_chats_reference INTEGER NOT NULL DEFAULT 0,
  recent_chats_summary_message_count INTEGER NOT NULL DEFAULT 5,
  memory_record_prompt TEXT NOT NULL DEFAULT '',
  docx_mode TEXT NOT NULL DEFAULT 'extract',
  pdf_mode TEXT NOT NULL DEFAULT 'extract',
  other_office_mode TEXT NOT NULL DEFAULT 'direct',
  enable_time_injection INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''');
    raw.execute('''
CREATE TABLE conversation_rows (
  id TEXT NOT NULL PRIMARY KEY,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  is_pinned INTEGER NOT NULL DEFAULT 0,
  assistant_id TEXT NULL,
  truncate_index INTEGER NOT NULL DEFAULT -1,
  version_selections_json TEXT NOT NULL DEFAULT '{}',
  summary TEXT NULL,
  last_summarized_message_count INTEGER NOT NULL DEFAULT 0,
  chat_suggestions_json TEXT NOT NULL DEFAULT '[]',
  parent_conversation_id TEXT NULL
);
''');
    raw.execute('''
CREATE TABLE message_rows (
  id TEXT NOT NULL PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  model_id TEXT NULL,
  provider_id TEXT NULL,
  total_tokens INTEGER NULL,
  is_streaming INTEGER NOT NULL DEFAULT 0,
  reasoning_text TEXT NULL,
  reasoning_start_at INTEGER NULL,
  reasoning_finished_at INTEGER NULL,
  translation TEXT NULL,
  reasoning_segments_json TEXT NULL,
  group_id TEXT NULL,
  subgroup_id TEXT NULL,
  version INTEGER NOT NULL DEFAULT 0,
  prompt_tokens INTEGER NULL,
  completion_tokens INTEGER NULL,
  cached_tokens INTEGER NULL,
  duration_ms INTEGER NULL,
  message_order INTEGER NOT NULL,
  is_preset INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (conversation_id) REFERENCES conversation_rows (id) ON DELETE CASCADE
);
''');
    raw.close();

    final repo = ChatDatabaseRepository.open(file: dbFile);
    await repo.ensureReady();

    // Must succeed: heal adds discoverable/handoff_* before Drift INSERT.
    await repo.putAssistant(
      Assistant(id: 'a1', name: 'Alpha', systemPrompt: 'hi'),
      sortOrder: 0,
    );
    final loaded = await repo.getAllAssistants();
    expect(loaded, hasLength(1));
    expect(loaded.first.name, 'Alpha');
    expect(loaded.first.discoverable, isFalse);

    await repo.close();
  });
}
