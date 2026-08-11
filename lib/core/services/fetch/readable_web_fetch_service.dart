import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:html2md/html2md.dart' as html2md;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;

import 'web_fetch_target_guard.dart' as guard;

class ReadableWebFetchResult {
  final String url;
  final String? title;
  final String content;
  final bool isMarkdown;

  const ReadableWebFetchResult({
    required this.url,
    this.title,
    required this.content,
    required this.isMarkdown,
  });
}

class UnsupportedReadableContentException implements Exception {
  final String message;

  const UnsupportedReadableContentException(this.message);

  @override
  String toString() => message;
}

/// Fetches a URL and converts readable text content for model consumption.
class ReadableWebFetchService {
  static const _binarySniffBytes = 1024;

  const ReadableWebFetchService._();

  static Future<ReadableWebFetchResult> fetch({
    required Uri url,
    Map<String, String> headers = const {},
    bool raw = false,
    Duration timeout = const Duration(seconds: 60),
    http.Client? client,
  }) async {
    final rawClient = client == null ? HttpClient() : null;
    final effectiveClient = client ?? IOClient(rawClient!);
    try {
      final response = await _getWithRedirectGuard(
        effectiveClient,
        url,
        headers,
        timeout,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final contentType = (response.headers['content-type'] ?? '')
          .toLowerCase();
      final bytes = response.bodyBytes;
      if (_looksBinary(bytes, contentType: contentType)) {
        throw const UnsupportedReadableContentException(
          'Binary content is not supported for readable page fetching.',
        );
      }
      final body = _decodeBody(response, bytes);
      final isMarkdown = !raw && _isHtml(body, contentType: contentType);
      final String content;
      String? title;
      if (raw) {
        content = body;
      } else if (isMarkdown) {
        final parsed = _htmlToDocument(body);
        title = _titleFrom(parsed);
        content = _markdownFrom(parsed, body);
      } else {
        content = _contentForModel(body, contentType: contentType);
      }
      return ReadableWebFetchResult(
        url: url.toString(),
        title: title?.isEmpty == true ? null : title,
        content: content,
        isMarkdown: isMarkdown,
      );
    } on UnsupportedReadableContentException {
      rethrow;
    } catch (error) {
      throw Exception('Failed to fetch $url: $error');
    } finally {
      rawClient?.close(force: true);
    }
  }

  /// Fetches [url], following redirects manually so every hop is re-validated
  /// by the SSRF guard before a socket opens. Redirects are capped at
  /// [guard.WebFetchTargetGuard.maxRedirectHops]. The whole operation (all
  /// hops plus body reads) is bounded by [timeout], so a slow-loris server
  /// trickling chunks inside the per-chunk window cannot extend it forever.
  static Future<http.Response> _getWithRedirectGuard(
    http.Client client,
    Uri url,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    var current = url;
    for (var hop = 0; hop <= guard.WebFetchTargetGuard.maxRedirectHops; hop++) {
      final reason = await guard.webFetchTargetBlockReason(current);
      if (reason != null) {
        throw Exception(reason);
      }
      final request = http.Request('GET', current)
        ..headers.addAll(headers)
        ..followRedirects = false;
      final hopTimeout = remaining();
      if (hopTimeout == Duration.zero) {
        throw TimeoutException('Web fetch timed out', timeout);
      }
      final streamed = await client.send(request).timeout(hopTimeout);
      if (_isRedirect(streamed.statusCode)) {
        final location = streamed.headers['location'];
        await streamed.stream.drain<void>();
        if (location == null || location.isEmpty) {
          throw Exception('Redirect without a Location header');
        }
        current = current.resolve(location);
        continue;
      }
      final bytes = <int>[];
      await for (final chunk in streamed.stream.timeout(remaining())) {
        bytes.addAll(chunk);
      }
      return http.Response.bytes(
        bytes,
        streamed.statusCode,
        headers: streamed.headers,
        reasonPhrase: streamed.reasonPhrase,
        persistentConnection: streamed.persistentConnection,
      );
    }
    throw Exception('Too many redirects');
  }

  static bool _isRedirect(int statusCode) =>
      statusCode >= 300 && statusCode < 400;

  static String _decodeBody(http.Response response, List<int> bytes) {
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (RegExp(r'charset\s*=').hasMatch(contentType)) return response.body;
    try {
      return utf8.decode(bytes);
    } on FormatException catch (error) {
      debugPrint(
        '[web_fetch] UTF-8 decode failed, using HTTP decoding: $error',
      );
      return response.body;
    }
  }

  static bool _looksBinary(List<int> bytes, {required String contentType}) {
    const binaryPrefixes = [
      'image/',
      'audio/',
      'video/',
      'application/pdf',
      'application/zip',
      'application/gzip',
      'application/x-tar',
      'application/x-7z-compressed',
      'application/x-rar-compressed',
      'application/octet-stream',
    ];
    if (binaryPrefixes.any(contentType.startsWith)) return true;
    final count = math.min(bytes.length, _binarySniffBytes);
    for (var index = 0; index < count; index++) {
      if (bytes[index] == 0) return true;
    }
    return false;
  }

  static String _contentForModel(String body, {required String contentType}) {
    if (_isHtml(body, contentType: contentType)) return _htmlToMarkdown(body);
    if (contentType.contains('application/json') ||
        contentType.contains('+json')) {
      try {
        return jsonEncode(jsonDecode(body));
      } catch (error) {
        debugPrint('[web_fetch] JSON compaction failed: $error');
        return body.trim();
      }
    }
    return body.trim();
  }

  static bool _isHtml(String body, {required String contentType}) {
    if (contentType.contains('text/html') ||
        contentType.contains('application/xhtml+xml')) {
      return true;
    }
    if (contentType.isNotEmpty) return false;
    final prefix = body.length > 256 ? body.substring(0, 256) : body;
    return RegExp(
      r'<\s*(?:!doctype\s+html|html)\b',
      caseSensitive: false,
    ).hasMatch(prefix);
  }

  static dom.Document _htmlToDocument(String html) {
    final document = html_parser.parse(html);
    document
        .querySelectorAll(
          'script,style,noscript,template,svg,iframe,nav,aside,footer,form',
        )
        .forEach((element) => element.remove());
    return document;
  }

  static String? _titleFrom(dom.Document document) =>
      document.querySelector('title')?.text.trim();

  static String _markdownFrom(dom.Document document, String html) {
    final mainContent = document.querySelector('main,article,[role="main"]');
    final source = mainContent?.outerHtml ?? document.body?.innerHtml ?? html;
    final markdown = html2md.convert(source).trim();
    if (markdown.isNotEmpty) {
      return markdown.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    }
    return (mainContent?.text ?? document.body?.text ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _htmlToMarkdown(String html) =>
      _markdownFrom(_htmlToDocument(html), html);
}
