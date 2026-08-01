import 'dart:io';

import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cuplivo_sync_open_');
    dbFile = File(p.join(tempDir.path, AppDatabase.databaseFileName));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('ensureReady opens sync connection after migration; cache reads kind', () async {
    final repo = ChatDatabaseRepository.open(file: dbFile);
    // Before ensureReady, sync path must not be required to work.
    await repo.ensureReady();

    final conversation = Conversation(
      title: 'hello',
      conversationKind: Conversation.kindNormal,
    );
    await repo.putConversation(conversation);

    final listed = repo.getAllConversationsSync(includeGroup: true);
    expect(listed.map((c) => c.id), contains(conversation.id));
    expect(listed.singleWhere((c) => c.id == conversation.id).isGroup, isFalse);

    final group = Conversation(
      title: 'g',
      conversationKind: Conversation.kindGroup,
    );
    await repo.putConversation(group);
    // Reopen sync so it sees the new row (and schema remains v14).
    repo.reopenSyncConnection();
    final nonGroup = repo.getAllConversationsSync(includeGroup: false);
    expect(nonGroup.any((c) => c.id == group.id), isFalse);
    final all = repo.getAllConversationsSync(includeGroup: true);
    expect(all.any((c) => c.id == group.id), isTrue);

    await repo.close();
  });
}
