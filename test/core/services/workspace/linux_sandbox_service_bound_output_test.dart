import 'dart:convert';

import 'package:Cuplivo/core/models/workspace.dart';
import 'package:Cuplivo/core/services/workspace/linux_sandbox_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinuxSandboxService.boundOutput', () {
    test('leaves short output untouched', () {
      const value = 'hello';
      expect(LinuxSandboxService.boundOutput(value), value);
    });

    test('truncates long ASCII output with a marker', () {
      final value = 'x' * (LinuxSandboxService.maxOutputChars + 100);
      final out = LinuxSandboxService.boundOutput(value);
      expect(out.length, lessThanOrEqualTo(LinuxSandboxService.maxOutputChars));
      expect(out, contains('...[truncated]...'));
      expect(() => jsonEncode(out), returnsNormally);
    });

    test('never splits a surrogate pair at the head cut', () {
      const marker = '\n...[truncated]...\n';
      final head = (LinuxSandboxService.maxOutputChars - marker.length) ~/ 2;
      // '😀' is U+1F600 = \uD83D\uDE00, a true surrogate pair (two code
      // units). Its high surrogate lands at head-1 and its low at head, so
      // the head cut falls exactly between them.
      final value =
          '${'a' * (head - 1)}😀'
          '${'b' * (LinuxSandboxService.maxOutputChars - head + 20)}';
      final out = LinuxSandboxService.boundOutput(value);
      expectValidUtf16(out);
      expect(() => jsonEncode(out), returnsNormally);
    });

    test('never splits a surrogate pair at the tail cut', () {
      const marker = '\n...[truncated]...\n';
      final available = LinuxSandboxService.maxOutputChars - marker.length;
      final head = available ~/ 2;
      final tail = available - head;
      final total = LinuxSandboxService.maxOutputChars + 24;
      final tailStart = total - tail;
      // '😀' straddles the tail start: its high surrogate is at tailStart-1
      // and its low at tailStart, so the tail cut falls exactly between them.
      final value =
          '${'a' * (tailStart - 1)}😀${'b' * (total - tailStart - 1)}';
      final out = LinuxSandboxService.boundOutput(value);
      expectValidUtf16(out);
      expect(() => jsonEncode(out), returnsNormally);
    });
  });

  group('LinuxSandboxService dependency probe', () {
    test('probes every non-base dependency in one fixed shell command', () {
      final command = LinuxSandboxService.dependencyProbeCommand();

      expect(command, contains('command -v python3'));
      expect(command, contains('command -v node'));
      expect(command, contains('command -v git'));
      expect(command, contains('command -v soffice'));
      expect(command, contains('command -v gcc'));
      for (final depId in WorkspaceDependencyIds.ordered.skip(1)) {
        expect(command, contains('__cuplivo_dependency__:$depId=1'));
        expect(command, contains('__cuplivo_dependency__:$depId=0'));
      }
    });

    test('parses complete, partial, and malformed probe output safely', () {
      final parsed = LinuxSandboxService.parseDependencyProbeOutput('''
__cuplivo_dependency__:python=1
__cuplivo_dependency__:nodejs=0
ordinary command output
__cuplivo_dependency__:office=unexpected
__cuplivo_dependency__:unknown=1
__cuplivo_dependency__:git=1
''');

      expect(parsed[WorkspaceDependencyIds.python], isTrue);
      expect(parsed[WorkspaceDependencyIds.nodejs], isFalse);
      expect(parsed[WorkspaceDependencyIds.git], isTrue);
      expect(parsed[WorkspaceDependencyIds.office], isFalse);
      expect(parsed[WorkspaceDependencyIds.buildEssential], isFalse);
      expect(parsed.containsKey('unknown'), isFalse);
    });
  });
}

void expectValidUtf16(String value) {
  for (var i = 0; i < value.length; i++) {
    final codeUnit = value.codeUnitAt(i);
    if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
      expect(
        i + 1 < value.length &&
            value.codeUnitAt(i + 1) >= 0xDC00 &&
            value.codeUnitAt(i + 1) <= 0xDFFF,
        isTrue,
        reason: 'lone high surrogate at $i',
      );
      i++;
    } else if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
      fail('lone low surrogate at $i');
    }
  }
}
