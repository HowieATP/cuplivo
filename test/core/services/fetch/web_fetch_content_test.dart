import 'package:Cuplivo/core/services/fetch/web_fetch_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebFetchContentWindow', () {
    test('returns a continuation window and next index', () {
      final window = WebFetchContentWindow.fromText(
        'abcdefghij',
        startIndex: 2,
        maxLength: 4,
      );

      expect(window.content, 'cdef');
      expect(window.startIndex, 2);
      expect(window.endIndex, 6);
      expect(window.totalLength, 10);
      expect(window.truncated, isTrue);
      expect(window.nextStartIndex, 6);
    });

    test('returns an empty terminal window past the end', () {
      final window = WebFetchContentWindow.fromText(
        'abc',
        startIndex: 20,
        maxLength: 5,
      );

      expect(window.content, isEmpty);
      expect(window.startIndex, 3);
      expect(window.endIndex, 3);
      expect(window.truncated, isFalse);
      expect(window.nextStartIndex, isNull);
    });

    test('never splits a UTF-16 surrogate pair at either boundary', () {
      const text = 'A😀BC';

      final first = WebFetchContentWindow.fromText(
        text,
        startIndex: 0,
        maxLength: 2,
      );
      final manualContinuation = WebFetchContentWindow.fromText(
        text,
        startIndex: 2,
        maxLength: 2,
      );

      expect(first.content, 'A');
      expect(first.nextStartIndex, 1);
      expect(manualContinuation.content, '😀');
      expect(manualContinuation.startIndex, 1);
      expect(manualContinuation.endIndex, 3);
    });

    test('rejects a negative start index', () {
      expect(
        () =>
            WebFetchContentWindow.fromText('abc', startIndex: -1, maxLength: 2),
        throwsArgumentError,
      );
    });

    test('rejects a zero or out-of-range max length', () {
      for (final maxLength in [0, 20001]) {
        expect(
          () => WebFetchContentWindow.fromText(
            'abc',
            startIndex: 0,
            maxLength: maxLength,
          ),
          throwsArgumentError,
          reason: 'maxLength $maxLength must be rejected',
        );
      }
    });

    test('rejects an exact-boundary surrogate split at the end', () {
      // `end - start == 1` with a high surrogate at end-1 must not loop.
      const text = '😀A';
      final window = WebFetchContentWindow.fromText(
        text,
        startIndex: 0,
        maxLength: 1,
      );
      // '😀' is a surrogate pair; maxLength 1 forces end==start+1, which is
      // extended to 2 so the pair is never torn.
      expect(window.content, '😀');
      expect(window.endIndex, 2);
      expect(window.nextStartIndex, 2);
    });
  });
}
