import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/utils/markdown_subsequence_match.dart';

void main() {
  group('subsequenceMatch', () {
    test('direct substring match returns the matching fragment', () {
      final result = subsequenceMatch('hello world', 'world');
      expect(result, 'world');
    });

    test('match skipping bold syntax', () {
      // Tightest span includes trailing **, excludes leading **
      final result = subsequenceMatch('**bold** text', 'bold text');
      expect(result, 'bold** text');
    });

    test('match skipping heading prefix', () {
      final result = subsequenceMatch('## Title', 'Title');
      expect(result, 'Title');
    });

    test('match skipping link syntax', () {
      // Tightest match lands inside [click here](url), excluding brackets
      final result = subsequenceMatch('[click here](url)', 'click here');
      expect(result, 'click here');
    });

    test('match across multiple inline spans', () {
      // Internal delimiters preserved, outer ones excluded
      final result = subsequenceMatch(
        '**bold** and *italic*',
        'bold and italic',
      );
      expect(result, 'bold** and *italic');
    });

    test('match code block content', () {
      // Code fences are outside the span
      final result = subsequenceMatch(
        '```dart\nvoid main() {}\n```',
        'void main() {}',
      );
      expect(result, 'void main() {}');
    });

    test('match across list items', () {
      // First prefix excluded, intermediate prefix included
      final result = subsequenceMatch(
        '- item one\n- item two\n- item three',
        'item one\nitem two',
      );
      expect(result, 'item one\n- item two');
    });

    test('tightest match wins', () {
      // First occurrence "the" inside **the** has span 3 (tightest)
      final result = subsequenceMatch('**the** cat and **the** dog', 'the');
      expect(result, 'the');
    });

    test(
      'tightest match prefers later exact substring over early loose match',
      () {
        final result = subsequenceMatch(
          'the answer is 42. the question is unknown.',
          'the question',
        );
        expect(result, 'the question');
      },
    );

    test('returns null for empty query', () {
      expect(subsequenceMatch('hello', ''), isNull);
    });

    test('returns null for empty source', () {
      expect(subsequenceMatch('', 'hello'), isNull);
    });

    test('returns null when query longer than source', () {
      expect(subsequenceMatch('abc', 'abcd'), isNull);
    });

    test('returns null when query is not a subsequence', () {
      expect(subsequenceMatch('hello', 'xyz'), isNull);
    });

    test('matches single character at tightest position', () {
      final result = subsequenceMatch('hello', 'e');
      expect(result, 'e');
    });

    test('matches entire source', () {
      final result = subsequenceMatch('hello world', 'hello world');
      expect(result, 'hello world');
    });

    test('handles CJK', () {
      final result = subsequenceMatch('你好世界', '世界');
      expect(result, '世界');
    });

    test('match across blocks with newlines preserved', () {
      final result = subsequenceMatch(
        '# heading\n\n**bold** and `code`',
        'heading\n\nbold and code',
      );
      expect(result, 'heading\n\n**bold** and `code');
    });

    // --- Normalization tests ---

    test('folds \\r\\n to \\n', () {
      final result = subsequenceMatch('- a\r\n- b', 'a\nb');
      expect(result, 'a\r\n- b');
    });

    test('folds consecutive newlines in query', () {
      // Source has a single newline between items; query has two
      final result = subsequenceMatch('- a\n- b', 'a\n\nb');
      expect(result, 'a\n- b');
    });

    test('strips ZWNJ (\\u200c) from query', () {
      final result = subsequenceMatch('hello\u200c world', 'hello world');
      expect(result, 'hello\u200c world');
    });

    test('strips bullet character from query', () {
      // • stripped, leading space preserved in match
      final result = subsequenceMatch('- item text', '• item text');
      expect(result, ' item text');
    });

    test('strips ZWSP (\\u200b) from query', () {
      final result = subsequenceMatch('hello', 'h\u200bello');
      expect(result, 'hello');
    });

    test('returns null when normalization empties the query', () {
      expect(subsequenceMatch('hello', '\u200b\u200c'), isNull);
    });
  });
}
