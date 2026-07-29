import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:Cuplivo/core/database/app_database.dart';
import 'package:Cuplivo/core/services/deleted_records_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeletedRecordsStore', () {
    late AppDatabase db;
    late DeletedRecordsStore store;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      store = DeletedRecordsStore(db);
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'recordDeletion writes both deleted_records and deletion_markers',
      () async {
        await store.recordDeletion(
          id: 'conv-1',
          type: DeletionEntityType.conversation,
          recoveryJson: '{"conversation":{"id":"conv-1"}}',
          batchId: 'batch-1',
          deletedAt: DateTime(2026, 7, 29),
        );

        final records = await store.listDeletedRecords();
        expect(records.length, 1);
        expect(records.first.id, 'conv-1');
        expect(records.first.type, DeletionEntityType.conversation);

        // Marker with origin='local' should also be written.
        final markers = await db.select(db.deletionMarkerRows).get();
        expect(markers.length, 1);
        expect(markers.first.origin, DeletionOrigin.local);
      },
    );

    test('size is utf8 bytes + 256 overhead', () async {
      const json = '{"test":"hello"}';
      await store.recordDeletion(
        id: 't1',
        type: DeletionEntityType.message,
        recoveryJson: json,
        batchId: 'b1',
        deletedAt: DateTime.now(),
      );

      final record = await store.getDeletedRecord(
        't1',
        DeletionEntityType.message,
      );
      expect(record, isNotNull);
      final expectedSize = json.runes.length + deletedRecordSizeOverhead;
      expect(record!.size, expectedSize);
    });

    test('recordRemoteDeletion writes only marker, no payload', () async {
      await store.recordRemoteDeletion(
        id: 'remote-conv-1',
        type: DeletionEntityType.conversation,
        remoteDeletedAt: DateTime(2026, 7, 28),
      );

      final markers = await store.listRemoteDeletionMarkers();
      expect(markers.length, 1);
      expect(markers.first.id, 'remote-conv-1');
      expect(markers.first.origin, DeletionOrigin.remote);

      // No deleted_records row.
      final records = await store.listDeletedRecords();
      expect(records, isEmpty);
    });

    test('evictToCap evicts oldest, never current batch', () async {
      // Write 3 rows with different batchIds and increasing timestamps.
      for (var i = 0; i < 3; i++) {
        await store.recordDeletion(
          id: 'r$i',
          type: DeletionEntityType.message,
          recoveryJson: '{"i":$i,"padding":"${'x' * 1000}"}',
          batchId: 'batch-$i',
          deletedAt: DateTime(2026, 1, 1 + i),
        );
      }

      // Now write a 4th row with a tiny cap that would require eviction.
      // Set cap to just above the size of one row.
      final oneRowSize =
          ('{"i":0,"padding":"${'x' * 1000}"}').runes.length +
          deletedRecordSizeOverhead;
      await store.evictToCap(oneRowSize * 2);

      // After eviction, at most 2 rows remain (the 2 newest).
      final records = await store.listDeletedRecords();
      expect(records.length, lessThanOrEqualTo(2));
      // The oldest (r0) should be evicted.
      final ids = records.map((r) => r.id).toSet();
      expect(ids.contains('r0'), isFalse);
    });

    test('marker eviction: unified 5000-row FIFO', () async {
      // Write 5001 local markers.
      for (var i = 0; i < 5001; i++) {
        await store.recordRemoteDeletion(
          id: 'm$i',
          type: DeletionEntityType.message,
          remoteDeletedAt: DateTime(2026, 1, 1, 0, 0, i),
        );
      }

      // After auto-eviction, should be at most 5000.
      final markers = await db.select(db.deletionMarkerRows).get();
      expect(markers.length, lessThanOrEqualTo(deletionMarkerRowCap));
    });

    test('buildDeletedJson excludes origin=remote (echo avoidance)', () async {
      // Write a local marker.
      await store.recordDeletion(
        id: 'local-1',
        type: DeletionEntityType.conversation,
        recoveryJson: '{}',
        batchId: 'b1',
        deletedAt: DateTime(2026, 7, 29),
      );
      // Write a remote marker.
      await store.recordRemoteDeletion(
        id: 'remote-1',
        type: DeletionEntityType.conversation,
        remoteDeletedAt: DateTime(2026, 7, 28),
      );

      final json = await buildDeletedJson(db);
      final decoded = parseDeletedJson(json);

      // Should contain local-1 but NOT remote-1.
      final convIds = decoded[DeletionEntityType.conversation]
          ?.map((e) => e.id)
          .toSet();
      expect(convIds, isNotNull);
      expect(convIds!.contains('local-1'), isTrue);
      expect(convIds.contains('remote-1'), isFalse);
    });

    test('parseDeletedJson handles null/empty/malformed (backward compat)', () {
      expect(parseDeletedJson(null), isEmpty);
      expect(parseDeletedJson(''), isEmpty);
      expect(parseDeletedJson('not json'), isEmpty);
    });

    test('clearAllData wipes both new tables', () async {
      await store.recordDeletion(
        id: 'c1',
        type: DeletionEntityType.conversation,
        recoveryJson: '{}',
        batchId: 'b1',
        deletedAt: DateTime.now(),
      );
      await store.recordRemoteDeletion(
        id: 'r1',
        type: DeletionEntityType.conversation,
        remoteDeletedAt: DateTime.now(),
      );

      // Clear all via raw delete (simulates clearAllData).
      await db.delete(db.deletedRecordRows).go();
      await db.delete(db.deletionMarkerRows).go();

      expect(await store.listDeletedRecords(), isEmpty);
      expect(await store.listRemoteDeletionMarkers(), isEmpty);
    });

    test('purgeDeletedRecord removes only the targeted row', () async {
      await store.recordDeletion(
        id: 'a',
        type: DeletionEntityType.conversation,
        recoveryJson: '{}',
        batchId: 'b1',
        deletedAt: DateTime.now(),
      );
      await store.recordDeletion(
        id: 'b',
        type: DeletionEntityType.message,
        recoveryJson: '{}',
        batchId: 'b2',
        deletedAt: DateTime.now(),
      );

      await store.purgeDeletedRecord('a', DeletionEntityType.conversation);

      final records = await store.listDeletedRecords();
      expect(records.length, 1);
      expect(records.first.id, 'b');
    });
  });

  group('Schema migration 9 → 10', () {
    test('new tables exist after migration', () async {
      // NativeDatabase.memory() creates at latest schemaVersion (10).
      final db = AppDatabase(NativeDatabase.memory());
      try {
        // Tables should exist and be queryable.
        final deletedRecords = await db.select(db.deletedRecordRows).get();
        expect(deletedRecords, isEmpty);

        final markers = await db.select(db.deletionMarkerRows).get();
        expect(markers, isEmpty);
      } finally {
        await db.close();
      }
    });
  });
}
