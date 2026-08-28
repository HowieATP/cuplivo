import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'web_chat_protocol.dart';

typedef WebChatHttpClientFactory = http.Client Function();

class WebChatRemoteImage {
  const WebChatRemoteImage({required this.mime, required this.bytes});

  final String mime;
  final Uint8List bytes;
}

class WebChatRemoteImageLoader {
  WebChatRemoteImageLoader({
    required this.clientFactory,
    this.maxBytes = 16 * 1024 * 1024,
    this.timeout = const Duration(seconds: 12),
  }) : assert(maxBytes > 0),
       assert(timeout > Duration.zero);

  static const Set<String> _allowedMimeTypes = <String>{
    'image/avif',
    'image/gif',
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  final WebChatHttpClientFactory clientFactory;
  final int maxBytes;
  final Duration timeout;

  Future<WebChatRemoteImage> load(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const WebChatProtocolException('remote media URL is invalid');
    }
    final client = clientFactory();
    final stopwatch = Stopwatch()..start();
    try {
      final request = http.Request('GET', uri)
        ..headers['Accept'] =
            'image/avif,image/webp,image/png,image/jpeg,image/gif';
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw WebChatProtocolException(
          'remote media HTTP ${response.statusCode}',
        );
      }
      final mime = (response.headers['content-type'] ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      if (!_allowedMimeTypes.contains(mime)) {
        throw const WebChatProtocolException(
          'remote media content type is not allowed',
        );
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maxBytes) {
        throw const WebChatProtocolException('remote media exceeds size limit');
      }
      final builder = BytesBuilder(copy: false);
      final iterator = StreamIterator<List<int>>(response.stream);
      var total = 0;
      try {
        while (true) {
          final remaining = timeout - stopwatch.elapsed;
          if (remaining <= Duration.zero) {
            throw TimeoutException('remote media download timed out');
          }
          if (!await iterator.moveNext().timeout(remaining)) break;
          final chunk = iterator.current;
          total += chunk.length;
          if (total > maxBytes) {
            throw const WebChatProtocolException(
              'remote media exceeds size limit',
            );
          }
          builder.add(chunk);
        }
      } finally {
        await iterator.cancel();
      }
      if (total == 0) {
        throw const WebChatProtocolException('remote media body is empty');
      }
      return WebChatRemoteImage(mime: mime, bytes: builder.takeBytes());
    } finally {
      client.close();
    }
  }
}
