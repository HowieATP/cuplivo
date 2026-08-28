import 'dart:convert';

import 'package:Cuplivo/core/models/web_conversation_style.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> styleJson({
  String id = 'soft-cards',
  int schemaVersion = 1,
  Map<String, dynamic>? common,
  Map<String, dynamic>? light,
  Map<String, dynamic>? dark,
}) => {
  'kind': webConversationStyleKind,
  'schemaVersion': schemaVersion,
  'id': id,
  'name': 'Soft Cards',
  'description': 'Optional description',
  'common':
      common ??
      {
        'userBubble': {'cornerRadius': 12},
      },
  'light': light ?? <String, dynamic>{},
  'dark': dark ?? <String, dynamic>{},
};

void main() {
  group('WebConversationStyle parser', () {
    test('validates and merges common with light and dark overrides', () {
      final style = WebConversationStyle.fromRaw(
        styleJson(
          common: {
            'userBubble': {
              'backgroundColor': '#112233',
              'textColor': '#FFFFFFAA',
              'cornerRadius': 12,
            },
            'processCard': {'accentColor': '#445566'},
          },
          light: {
            'userBubble': {'cornerRadius': 20},
          },
          dark: {
            'assistantBubble': {'borderWidth': 1},
          },
        ),
      );

      expect(style.id, 'soft-cards');
      expect(style.resolveAppearance(isDark: false), {
        'userBubble': {
          'backgroundColor': '#112233',
          'textColor': '#FFFFFFAA',
          'cornerRadius': 20.0,
        },
        'processCard': {'accentColor': '#445566'},
      });
      expect(style.resolveAppearance(isDark: true), {
        'userBubble': {
          'backgroundColor': '#112233',
          'textColor': '#FFFFFFAA',
          'cornerRadius': 12.0,
        },
        'assistantBubble': {'borderWidth': 1.0},
        'processCard': {'accentColor': '#445566'},
      });
    });

    test('accepts every numeric boundary', () {
      final style = WebConversationStyle.fromRaw(
        styleJson(
          common: {
            'userBubble': {
              'borderWidth': 0,
              'cornerRadius': 48,
              'paddingHorizontal': 32,
              'paddingVertical': 0,
              'shadowElevation': 24,
              'maxWidthPercent': 40,
            },
            'assistantBubble': {'maxWidthPercent': 100},
            'processCard': {'borderWidth': 4},
          },
        ),
      );
      expect(style.resolveAppearance(isDark: false), isNotEmpty);
    });

    test('rejects numeric values outside every boundary', () {
      const invalid = <String, num>{
        'borderWidth': 4.01,
        'cornerRadius': 48.01,
        'paddingHorizontal': 32.01,
        'paddingVertical': -0.01,
        'shadowElevation': 24.01,
        'maxWidthPercent': 39.99,
      };
      for (final entry in invalid.entries) {
        expect(
          () => WebConversationStyle.fromRaw(
            styleJson(
              common: {
                'userBubble': {entry.key: entry.value},
              },
            ),
          ),
          throwsA(
            isA<WebConversationStyleException>().having(
              (error) => error.code,
              'code',
              WebConversationStyleErrorCode.invalidField,
            ),
          ),
          reason: entry.key,
        );
      }
    });

    test('rejects invalid JSON, UTF-8, metadata, colors and types', () {
      expect(
        () => WebConversationStyle.parse('{'),
        throwsA(isA<WebConversationStyleException>()),
      );
      expect(
        () => WebConversationStyle.parseBytes([0xff]),
        throwsA(
          isA<WebConversationStyleException>().having(
            (error) => error.code,
            'code',
            WebConversationStyleErrorCode.invalidUtf8,
          ),
        ),
      );
      for (final mutation in <void Function(Map<String, dynamic>)>[
        (json) => json['kind'] = 'other',
        (json) => json['schemaVersion'] = '1',
        (json) => json['id'] = 'Not Valid',
        (json) => json['name'] = '',
        (json) => json['description'] = 'x' * 241,
        (json) => json['common'] = [],
        (json) => json['common'] = {'userBubble': 'bad'},
        (json) => json['common'] = {
          'userBubble': {'backgroundColor': '#12345'},
        },
        (json) => json['common'] = {
          'userBubble': {'cornerRadius': true},
        },
      ]) {
        final json = styleJson();
        mutation(json);
        expect(
          () => WebConversationStyle.fromRaw(json),
          throwsA(isA<WebConversationStyleException>()),
        );
      }
    });

    test(
      'warns on unknown and inapplicable fields while retaining raw JSON',
      () {
        final raw = styleJson(schemaVersion: 2)
          ..['futureRoot'] = {'kept': true}
          ..['common'] = {
            'futureSurface': {'x': 1},
            'userBubble': {'accentColor': '#112233', 'futureField': 7},
            'processCard': {
              'maxWidthPercent': 70,
              'backgroundColor': '#445566',
            },
          };
        final style = WebConversationStyle.fromRaw(raw);

        expect(style.warnings, contains(r'$.schemaVersion'));
        expect(style.warnings, contains(r'$.futureRoot'));
        expect(style.warnings, contains(r'$.common.futureSurface'));
        expect(style.warnings, contains(r'$.common.userBubble.futureField'));
        expect(style.warnings, contains(r'$.common.userBubble.accentColor'));
        expect(
          style.warnings,
          contains(r'$.common.processCard.maxWidthPercent'),
        );
        expect(jsonDecode(style.exportJson()), raw);
        expect(style.resolveAppearance(isDark: false), {
          'processCard': {'backgroundColor': '#445566'},
        });
      },
    );

    test('rejects a style without any applicable field', () {
      final raw = styleJson(
        common: {
          'userBubble': {'accentColor': '#112233'},
        },
      );
      expect(
        () => WebConversationStyle.fromRaw(raw),
        throwsA(
          isA<WebConversationStyleException>().having(
            (error) => error.code,
            'code',
            WebConversationStyleErrorCode.noApplicableFields,
          ),
        ),
      );
    });

    test('enforces the per-file byte limit', () {
      expect(
        () => WebConversationStyle.parseBytes(
          List<int>.filled(webConversationStyleFileByteLimit + 1, 32),
        ),
        throwsA(
          isA<WebConversationStyleException>().having(
            (error) => error.code,
            'code',
            WebConversationStyleErrorCode.fileTooLarge,
          ),
        ),
      );
    });
  });

  group('WebConversationStyleLibrary', () {
    WebConversationStyle makeStyle(String id, {String? name}) {
      final raw = styleJson(id: id);
      if (name != null) raw['name'] = name;
      return WebConversationStyle.fromRaw(raw);
    }

    test('adds and atomically updates by ID without changing active style', () {
      final original = makeStyle('same', name: 'Original');
      final other = makeStyle('other');
      final library = WebConversationStyleLibrary(
        entries: [original, other],
        activeId: 'same',
      );
      final replacement = makeStyle('same', name: 'Replacement');
      final updated = library.importBatch([replacement]);

      expect(updated.entries, hasLength(2));
      expect(updated.activeId, 'same');
      expect(updated.activeStyle?.name, 'Replacement');
      expect(library.activeStyle?.name, 'Original');
    });

    test('rejects duplicate IDs in one batch without changing source', () {
      final library = WebConversationStyleLibrary(entries: [makeStyle('old')]);
      expect(
        () => library.importBatch([makeStyle('new'), makeStyle('new')]),
        throwsA(
          isA<WebConversationStyleException>().having(
            (error) => error.code,
            'code',
            WebConversationStyleErrorCode.duplicateId,
          ),
        ),
      );
      expect(library.entries.single.id, 'old');
    });

    test('activates default/custom and deleting active returns to default', () {
      final library = WebConversationStyleLibrary(entries: [makeStyle('one')]);
      final active = library.activate('one');
      expect(active.activeStyle?.id, 'one');
      expect(active.activate(null).activeStyle, isNull);
      expect(active.remove('one').activeId, isNull);
    });

    test('round-trips persisted library and drops a missing active ID', () {
      final library = WebConversationStyleLibrary(
        entries: [makeStyle('one')],
        activeId: 'one',
      );
      final restored = WebConversationStyleLibrary.decode(library.encode());
      expect(restored.activeId, 'one');
      expect(restored.entries.single.raw, library.entries.single.raw);

      final decoded = jsonDecode(library.encode()) as Map<String, dynamic>;
      decoded['activeId'] = 'missing';
      expect(
        WebConversationStyleLibrary.decode(jsonEncode(decoded)).activeId,
        isNull,
      );
    });

    test('sorts imported entries stably by name then ID', () {
      final library = WebConversationStyleLibrary(
        entries: [
          makeStyle('z', name: 'Beta'),
          makeStyle('b', name: 'alpha'),
          makeStyle('a', name: 'Alpha'),
        ],
      );
      expect(library.sortedEntries.map((style) => style.id), ['a', 'b', 'z']);
    });

    test('defensively freezes the supplied entry list', () {
      final source = <WebConversationStyle>[makeStyle('one')];
      final library = WebConversationStyleLibrary(entries: source);
      source.add(makeStyle('two'));
      expect(library.entries.map((style) => style.id), ['one']);
      expect(() => library.entries.clear(), throwsUnsupportedError);
    });

    test('enforces entry and total raw JSON limits', () {
      final tooMany = [
        for (var i = 0; i <= webConversationStyleLibraryEntryLimit; i++)
          makeStyle('style-$i'),
      ];
      expect(
        () => WebConversationStyleLibrary(entries: tooMany).validateLimits(),
        throwsA(
          isA<WebConversationStyleException>().having(
            (error) => error.code,
            'code',
            WebConversationStyleErrorCode.tooManyEntries,
          ),
        ),
      );

      final large = <WebConversationStyle>[];
      for (var i = 0; i < 64; i++) {
        final raw = styleJson(id: 'large-$i')..['unknown'] = 'x' * 17000;
        large.add(WebConversationStyle.fromRaw(raw));
      }
      expect(
        () => WebConversationStyleLibrary(entries: large).validateLimits(),
        throwsA(
          isA<WebConversationStyleException>().having(
            (error) => error.code,
            'code',
            WebConversationStyleErrorCode.libraryTooLarge,
          ),
        ),
      );
    });
  });
}
