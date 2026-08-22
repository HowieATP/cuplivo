import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/home/services/ocr_service.dart';

void main() {
  group('OcrService LRU cache', () {
    test('caches text and returns it with recency bump', () {
      final service = OcrService();
      service.cacheOcrText('a', 'one');
      service.cacheOcrText('b', 'two');

      expect(service.getCachedOcrText('a'), 'one');
      expect(service.getCachedOcrText('b'), 'two');
      expect(service.cacheSize, 2);
    });

    test('LRU evicts oldest memory entries', () {
      final service = OcrService(maxCacheEntries: 2);
      service.cacheOcrText('h1', 'one');
      service.cacheOcrText('h2', 'two');
      service.cacheOcrText('h3', 'three');
      expect(service.cacheSize, 2);
      expect(service.getCachedOcrText('h1'), isNull);
      expect(service.getCachedOcrText('h2'), 'two');
      expect(service.getCachedOcrText('h3'), 'three');
    });

    test('access bumps recency so recently read entries survive eviction', () {
      final service = OcrService(maxCacheEntries: 2);
      service.cacheOcrText('h1', 'one');
      service.cacheOcrText('h2', 'two');
      service.getCachedOcrText('h1');
      service.cacheOcrText('h3', 'three');
      expect(service.cacheSize, 2);
      expect(service.getCachedOcrText('h1'), 'one');
      expect(service.getCachedOcrText('h2'), isNull);
      expect(service.getCachedOcrText('h3'), 'three');
    });

    test('empty and whitespace paths are ignored', () {
      final service = OcrService(maxCacheEntries: 2);
      service.cacheOcrText('   ', 'ignored');
      service.cacheOcrText('', 'ignored');
      expect(service.cacheSize, 0);
    });
  });

  group('OcrService request messages', () {
    test('includes a system message when the OCR prompt is set', () {
      expect(OcrService.buildOcrRequestMessages('Read the image.'), [
        {'role': 'system', 'content': 'Read the image.'},
        {'role': 'user', 'content': OcrService.defaultOcrUserPrompt},
      ]);
    });

    test('omits the system message when the OCR prompt is empty', () {
      expect(OcrService.buildOcrRequestMessages('   '), [
        {'role': 'user', 'content': OcrService.defaultOcrUserPrompt},
      ]);
    });
  });

  group('OcrService wrapOcrBlock', () {
    test('wraps extracted text in an image_file_ocr block', () {
      final block = OcrService().wrapOcrBlock('  extracted text  ');
      expect(block, contains('<image_file_ocr>'));
      expect(block, contains('extracted text'));
      expect(block, contains('</image_file_ocr>'));
    });
  });
}
