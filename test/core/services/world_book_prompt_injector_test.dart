import 'package:Cuplivo/core/models/world_book.dart';
import 'package:Cuplivo/core/services/world_book_prompt_injector.dart';
import 'package:flutter_test/flutter_test.dart';

WorldBookEntry entry({
  required String id,
  required String content,
  required WorldBookInjectionPosition position,
  int priority = 0,
  int injectDepth = 1,
  WorldBookInjectionRole role = WorldBookInjectionRole.user,
  List<String> keywords = const <String>[],
  bool useRegex = false,
  bool constantActive = true,
  bool enabled = true,
}) {
  return WorldBookEntry(
    id: id,
    content: content,
    position: position,
    priority: priority,
    injectDepth: injectDepth,
    role: role,
    keywords: keywords,
    useRegex: useRegex,
    constantActive: constantActive,
    enabled: enabled,
  );
}

void main() {
  group('WorldBookPromptInjector', () {
    test('preserves priority, roles, and all injection positions', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'persona'},
        {'role': 'user', 'content': 'older context'},
        {'role': 'assistant', 'content': 'reply'},
        {'role': 'user', 'content': 'care trigger'},
      ];
      final book = WorldBook(
        id: 'active',
        entries: [
          entry(
            id: 'before-low',
            content: 'before-low',
            position: WorldBookInjectionPosition.beforeSystemPrompt,
          ),
          entry(
            id: 'before-high',
            content: 'before-high',
            position: WorldBookInjectionPosition.beforeSystemPrompt,
            priority: 10,
          ),
          entry(
            id: 'after',
            content: 'after',
            position: WorldBookInjectionPosition.afterSystemPrompt,
          ),
          entry(
            id: 'top',
            content: 'top',
            position: WorldBookInjectionPosition.topOfChat,
          ),
          entry(
            id: 'bottom',
            content: 'bottom',
            position: WorldBookInjectionPosition.bottomOfChat,
            role: WorldBookInjectionRole.assistant,
          ),
          entry(
            id: 'depth',
            content: 'depth',
            position: WorldBookInjectionPosition.atDepth,
          ),
        ],
      );

      WorldBookPromptInjector.inject(
        messages: messages,
        books: [book],
        activeBookIds: const ['active'],
      );

      expect(
        messages.first['content'],
        'before-high\nbefore-low\npersona\nafter',
      );
      expect(messages.map((message) => message['role']), [
        'system',
        'user',
        'user',
        'assistant',
        'assistant',
        'user',
        'user',
      ]);
      expect(messages[1]['content'], '<system>\ntop\n</system>');
      expect(messages[4]['content'], 'bottom');
      expect(messages[5]['content'], '<system>\ndepth\n</system>');
      expect(messages.last['content'], 'care trigger');
    });

    test('honors active books, enabled flags, and keyword regex matching', () {
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'The care prompt mentions ALPHA-42.'},
      ];
      final books = [
        WorldBook(
          id: 'active',
          entries: [
            entry(
              id: 'keyword',
              content: 'keyword-hit',
              position: WorldBookInjectionPosition.afterSystemPrompt,
              keywords: const ['alpha-42'],
              constantActive: false,
            ),
            entry(
              id: 'regex',
              content: 'regex-hit',
              position: WorldBookInjectionPosition.afterSystemPrompt,
              keywords: const [r'ALPHA-\d+'],
              useRegex: true,
              constantActive: false,
            ),
            entry(
              id: 'disabled-entry',
              content: 'must-not-appear',
              position: WorldBookInjectionPosition.afterSystemPrompt,
              enabled: false,
            ),
          ],
        ),
        WorldBook(
          id: 'inactive',
          entries: [
            entry(
              id: 'inactive-entry',
              content: 'inactive-book-content',
              position: WorldBookInjectionPosition.afterSystemPrompt,
            ),
          ],
        ),
        WorldBook(
          id: 'disabled-book',
          enabled: false,
          entries: [
            entry(
              id: 'disabled-book-entry',
              content: 'disabled-book-content',
              position: WorldBookInjectionPosition.afterSystemPrompt,
            ),
          ],
        ),
      ];

      WorldBookPromptInjector.inject(
        messages: messages,
        books: books,
        activeBookIds: const ['active', 'disabled-book'],
      );

      expect(messages.first['role'], 'system');
      expect(messages.first['content'], 'keyword-hit\nregex-hit');
      expect(messages.toString(), isNot(contains('must-not-appear')));
      expect(messages.toString(), isNot(contains('inactive-book-content')));
      expect(messages.toString(), isNot(contains('disabled-book-content')));
    });
  });
}
