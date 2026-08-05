import 'package:Cuplivo/features/linux_sandbox/services/windows_wsl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hostPathToWsl', () {
    test('converts drive letter paths', () {
      expect(hostPathToWsl(r'C:\Users\foo'), '/mnt/c/Users/foo');
      expect(hostPathToWsl(r'D:\data\work'), '/mnt/d/data/work');
      expect(hostPathToWsl('E:\\'), '/mnt/e');
      expect(hostPathToWsl('e:'), '/mnt/e');
    });

    test('accepts forward slashes on Windows paths', () {
      expect(hostPathToWsl('C:/Users/foo/bar'), '/mnt/c/Users/foo/bar');
      expect(hostPathToWsl('c:/'), '/mnt/c');
    });

    test('lowercases drive letter', () {
      expect(hostPathToWsl(r'C:\X'), '/mnt/c/X');
      expect(hostPathToWsl(r'Z:\a\b'), '/mnt/z/a/b');
    });

    test('strips trailing separators', () {
      expect(hostPathToWsl(r'C:\Users\foo\'), '/mnt/c/Users/foo');
      expect(hostPathToWsl('C:/Users/foo/'), '/mnt/c/Users/foo');
    });

    test('passes through empty and non-drive paths', () {
      expect(hostPathToWsl(''), '');
      expect(hostPathToWsl('   '), '');
      expect(hostPathToWsl('/mnt/c/already'), '/mnt/c/already');
      expect(hostPathToWsl(r'relative\path'), 'relative/path');
    });
  });

  group('decodeWslOutput', () {
    test('decodes UTF-16LE with BOM', () {
      // "Ubuntu\n" in UTF-16LE with BOM
      final bytes = <int>[
        0xFF, 0xFE,
        0x55, 0x00, // U
        0x62, 0x00, // b
        0x75, 0x00, // u
        0x6E, 0x00, // n
        0x74, 0x00, // t
        0x75, 0x00, // u
        0x0A, 0x00, // \n
      ];
      expect(decodeWslOutput(bytes).trim(), 'Ubuntu');
    });

    test('decodes UTF-16LE without BOM', () {
      final bytes = <int>[
        0x41, 0x00, // A
        0x42, 0x00, // B
      ];
      expect(decodeWslOutput(bytes), 'AB');
    });

    test('decodes plain UTF-8', () {
      expect(decodeWslOutput('Ubuntu\n'.codeUnits).trim(), 'Ubuntu');
    });
  });
}
