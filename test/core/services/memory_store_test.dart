import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/database/business_preferences.dart';

import 'package:Cuplivo/core/models/assistant_memory.dart';
import 'package:Cuplivo/core/services/memory_store.dart';

var businessPrefs = BusinessPreferences.memoryForTests();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MemoryStore', () {
    setUp(() async {
      businessPrefs = BusinessPreferences.memoryForTests();
      businessPrefs = BusinessPreferences.memoryForTests({});
      await MemoryStore(businessPrefs).saveAll(<AssistantMemory>[]);
    });

    test(
      'parallel add() assigns unique ids without losing records (#478)',
      () async {
        final store = MemoryStore(businessPrefs);
        final results = await Future.wait([
          store.add(assistantId: 'a1', content: 'm1'),
          store.add(assistantId: 'a1', content: 'm2'),
          store.add(assistantId: 'a1', content: 'm3'),
          store.add(assistantId: 'a1', content: 'm4'),
        ]);

        final ids = results.map((m) => m.id).toSet();
        expect(
          ids.length,
          results.length,
          reason: 'parallel adds must not share ids',
        );

        final all = await store.getAll();
        final stored = all.where((m) => m.assistantId == 'a1').toList();
        expect(
          stored.length,
          results.length,
          reason: 'no record may be overwritten',
        );
        expect(stored.map((m) => m.id).toSet().length, results.length);
        expect(stored.map((m) => m.id), everyElement(isPositive));
      },
    );

    test('parallel add() continues from existing ids monotonically', () async {
      final store = MemoryStore(businessPrefs);
      await store.add(assistantId: 'a1', content: 'existing');

      final results = await Future.wait([
        store.add(assistantId: 'a1', content: 'm1'),
        store.add(assistantId: 'a1', content: 'm2'),
        store.add(assistantId: 'a1', content: 'm3'),
      ]);

      final ids = results.map((m) => m.id).toSet();
      expect(ids.length, results.length);
      expect(ids, isNot(contains(1)));
    });

    test('parallel add and delete serialize without lost updates', () async {
      final store = MemoryStore(businessPrefs);
      final first = await store.add(assistantId: 'a1', content: 'm1');

      await Future.wait([
        store.add(assistantId: 'a1', content: 'm2'),
        store.delete(id: first.id),
      ]);

      final all = await store.getAll();
      final stored = all.where((m) => m.assistantId == 'a1').toList();
      expect(
        stored.length,
        1,
        reason: 'exactly one record must survive either order',
      );
      expect(stored.single.content, 'm2');
    });
  });
}
