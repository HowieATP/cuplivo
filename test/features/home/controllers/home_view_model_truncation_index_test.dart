import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/features/home/controllers/home_view_model.dart';

ChatMessage _m({
  required String id,
  required String role,
  required String content,
  String? groupId,
  int version = 0,
  bool isPreset = false,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    conversationId: 'c1',
    groupId: groupId ?? id,
    version: version,
    isPreset: isPreset,
  );
}

void main() {
  group('HomeViewModel.computeTruncCollapsedIndex', () {
    test('truncRaw <= 0 returns -1', () {
      expect(
        HomeViewModel.computeTruncCollapsedIndex(truncRaw: 0, rawMessages: []),
        -1,
      );
      expect(
        HomeViewModel.computeTruncCollapsedIndex(truncRaw: -1, rawMessages: []),
        -1,
      );
    });

    test('maps raw index directly for unique groups', () {
      final msgs = [
        _m(id: 'm0', role: 'user', content: 'a'),
        _m(id: 'm1', role: 'assistant', content: 'b'),
        _m(id: 'm2', role: 'user', content: 'c'),
      ];

      expect(
        HomeViewModel.computeTruncCollapsedIndex(
          truncRaw: 2,
          rawMessages: msgs,
        ),
        1,
      );
    });

    test('deduplicates versioned messages by groupId', () {
      final msgs = [
        _m(id: 'm0', role: 'user', content: 'a', groupId: 'g1'),
        _m(id: 'm1', role: 'user', content: 'a2', groupId: 'g1', version: 1),
        _m(id: 'm2', role: 'assistant', content: 'b', groupId: 'g2'),
      ];

      // truncRaw=3: includes m0, m1, m2 → 2 unique groups → returns 1
      expect(
        HomeViewModel.computeTruncCollapsedIndex(
          truncRaw: 3,
          rawMessages: msgs,
        ),
        1,
      );
    });

    test('clamps truncRaw to rawMessages.length when larger', () {
      final msgs = [
        _m(id: 'm0', role: 'user', content: 'a'),
        _m(id: 'm1', role: 'assistant', content: 'b'),
      ];

      // truncRaw=10 but only 2 messages → limit=2 → count=2 → returns 1
      expect(
        HomeViewModel.computeTruncCollapsedIndex(
          truncRaw: 10,
          rawMessages: msgs,
        ),
        1,
      );
    });
  });

  group('HomeViewModel.adjustTruncIndexForPresetFolding', () {
    test('truncIndex < 0 returns -1', () {
      expect(
        HomeViewModel.adjustTruncIndexForPresetFolding(
          truncIndex: -1,
          presetCount: 3,
          showPresetToggle: true,
          presetsExpanded: false,
        ),
        -1,
      );
    });

    test('no preset toggle returns truncIndex unchanged', () {
      expect(
        HomeViewModel.adjustTruncIndexForPresetFolding(
          truncIndex: 4,
          presetCount: 3,
          showPresetToggle: false,
          presetsExpanded: false,
        ),
        4,
      );
    });

    test('presets expanded returns truncIndex unchanged', () {
      expect(
        HomeViewModel.adjustTruncIndexForPresetFolding(
          truncIndex: 4,
          presetCount: 3,
          showPresetToggle: true,
          presetsExpanded: true,
        ),
        4,
      );
    });

    test('presets folded, truncIndex >= presetCount subtracts presetCount', () {
      expect(
        HomeViewModel.adjustTruncIndexForPresetFolding(
          truncIndex: 4,
          presetCount: 3,
          showPresetToggle: true,
          presetsExpanded: false,
        ),
        1,
      );
    });

    test('presets folded, truncIndex < presetCount returns -1', () {
      expect(
        HomeViewModel.adjustTruncIndexForPresetFolding(
          truncIndex: 1,
          presetCount: 3,
          showPresetToggle: true,
          presetsExpanded: false,
        ),
        -1,
      );
    });

    test(
      'presets folded, exact boundary (truncIndex == presetCount) returns 0',
      () {
        expect(
          HomeViewModel.adjustTruncIndexForPresetFolding(
            truncIndex: 3,
            presetCount: 3,
            showPresetToggle: true,
            presetsExpanded: false,
          ),
          0,
        );
      },
    );

    test(
      'presets folded, truncIndex at last message returns correct index',
      () {
        // 5 collapsed messages: 3 presets, 2 real
        // truncIndex=4 (last message index)
        // after adjustment: 4-3 = 1 (last real message index in shortened list)
        expect(
          HomeViewModel.adjustTruncIndexForPresetFolding(
            truncIndex: 4,
            presetCount: 3,
            showPresetToggle: true,
            presetsExpanded: false,
          ),
          1,
        );
      },
    );
  });
}
