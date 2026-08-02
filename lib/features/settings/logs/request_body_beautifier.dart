import 'dart:convert';

/// Normalized role for a conversation turn shown in the beautified request body.
enum TurnRole { system, user, assistant, tool }

/// A single part within a turn. Turns are interleaved lists of text and
/// non-text parts (tool calls, images, thinking, etc.) in their original order.
sealed class TurnPart {}

class TextPart extends TurnPart {
  final String text;
  TextPart(this.text);
}

class ImagePart extends TurnPart {
  /// Filename if known (e.g. from OpenAI ``file`` parts), ``null`` otherwise.
  final String? filename;

  /// Remote URL if the image is a plain URL (not base64), ``null`` otherwise.
  final String? url;

  /// MIME type if known, ``null`` otherwise.
  final String? mime;

  /// Whether the payload is base64-encoded inline data.
  final bool isBase64;

  /// Decoded byte length of the base64 payload (0 if unknown / not base64).
  final int byteLength;

  ImagePart({
    this.filename,
    this.url,
    this.mime,
    this.isBase64 = false,
    this.byteLength = 0,
  });

  /// Compact display label: ``filename/url/mime (base64) · size``.
  String get displayLabel {
    final head = filename ?? url ?? mime ?? 'image';
    final base64Tag = isBase64 ? ' (base64)' : '';
    if (byteLength > 0) {
      return '$head$base64Tag · ${_describeBytes(byteLength)}';
    }
    return '$head$base64Tag';
  }
}

class FilePart extends TurnPart {
  final String filename;
  FilePart(this.filename);
}

class ToolCallPart extends TurnPart {
  final String name;

  /// Pretty-printed JSON arguments (or raw string if not JSON).
  final String arguments;
  ToolCallPart(this.name, this.arguments);
}

class ToolResultPart extends TurnPart {
  final String name;

  /// Pretty-printed JSON output (or raw string if not JSON).
  final String output;
  ToolResultPart(this.name, this.output);
}

class ThinkingPart extends TurnPart {
  final String content;
  ThinkingPart(this.content);
}

class RedactedThinkingPart extends TurnPart {
  final int byteLength;
  RedactedThinkingPart(this.byteLength);
}

/// One normalized conversation turn rendered as a left-border-accented block.
class BeautifiedTurn {
  final TurnRole role;
  final List<TurnPart> parts;
  const BeautifiedTurn(this.role, this.parts);
}

/// Result of beautifying a request body: colored turns on top, remaining
/// config fields pretty-printed below.
class BeautifiedBody {
  final List<BeautifiedTurn> turns;

  /// Pretty-printed JSON of the non-message fields. Empty string if none.
  final String configJson;
  const BeautifiedBody(this.turns, this.configJson);
}

/// Tries to parse [rawBody] into a [BeautifiedBody].
///
/// Returns `null` if the body is not valid JSON, not a JSON object, or does
/// not match any of the four supported LLM protocol structures.
BeautifiedBody? tryBeautify(String rawBody) {
  final trimmed = rawBody.trim();
  if (trimmed.isEmpty) return null;

  final dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;

  // Detection order: unique structural keys first.
  if (decoded.containsKey('input')) return _parseOpenAIResponses(decoded);
  if (decoded.containsKey('contents')) return _parseGemini(decoded);
  if (decoded.containsKey('messages')) {
    if (decoded['system'] is String || decoded['system'] is List) {
      return _parseClaude(decoded);
    }
    return _parseOpenAIChat(decoded);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Per-protocol parsers
// ---------------------------------------------------------------------------

BeautifiedBody _parseOpenAIChat(Map<String, dynamic> body) {
  final turns = <BeautifiedTurn>[];
  final messages = body['messages'] as List<dynamic>? ?? const [];

  for (final msg in messages) {
    if (msg is! Map<String, dynamic>) continue;
    final role = _normalizeRole(msg['role'] as String?);
    final parts = <TurnPart>[];

    final content = msg['content'];

    // Tool-role messages: content IS the tool result, no separate text part.
    if (role == TurnRole.tool) {
      final toolName = (msg['name'] as String?) ?? 'tool';
      if (content is List) {
        // Content-parts array (image-bearing tool results): keep text in the
        // result part and surface image parts alongside.
        final texts = <String>[];
        final mediaParts = <TurnPart>[];
        for (final part in content) {
          if (part is! Map<String, dynamic>) continue;
          final p = _parseOpenAIChatContentPart(part);
          if (p is TextPart) {
            texts.add(p.text);
          } else if (p != null) {
            mediaParts.add(p);
          }
        }
        if (texts.isNotEmpty) {
          parts.add(ToolResultPart(toolName, texts.join('\n')));
        }
        parts.addAll(mediaParts);
      } else {
        final resultStr = content is String ? content : _prettyOrRaw(content);
        parts.add(ToolResultPart(toolName, resultStr));
      }
    } else if (content is String && content.isNotEmpty) {
      parts.add(TextPart(content));
    } else if (content is List) {
      for (final part in content) {
        if (part is! Map<String, dynamic>) continue;
        final p = _parseOpenAIChatContentPart(part);
        if (p != null) parts.add(p);
      }
    }

    // Assistant tool calls.
    if (msg['tool_calls'] is List) {
      for (final tc in (msg['tool_calls'] as List)) {
        if (tc is! Map<String, dynamic>) continue;
        final fn = tc['function'] as Map<String, dynamic>?;
        parts.add(
          ToolCallPart(
            (fn?['name'] as String?) ?? 'unknown',
            _prettyOrRaw(fn?['arguments']),
          ),
        );
      }
    }

    // Some vendors echo reasoning on messages (typically assistant).
    // Two formats: reasoning_content (string) and reasoning_details (list
    // of {type: "reasoning.text", text: "..."} chunks from OpenRouter-style
    // streaming).
    final reasoning = msg['reasoning_content'];
    if (reasoning is String && reasoning.isNotEmpty) {
      parts.add(ThinkingPart(reasoning));
    }
    final reasoningDetails = msg['reasoning_details'];
    if (reasoningDetails is List) {
      final text = reasoningDetails
          .whereType<Map<String, dynamic>>()
          .map((d) => d['text'] as String?)
          .where((t) => t != null && t.isNotEmpty)
          .join();
      if (text.isNotEmpty) parts.add(ThinkingPart(text));
    }

    if (parts.isNotEmpty) turns.add(BeautifiedTurn(role, parts));
  }

  return BeautifiedBody(turns, _remainingJson(body, const {'messages'}));
}

BeautifiedBody _parseClaude(Map<String, dynamic> body) {
  final turns = <BeautifiedTurn>[];

  // Claude system prompt is a top-level string (or a list of blocks).
  final system = body['system'];
  if (system is String && system.isNotEmpty) {
    turns.add(BeautifiedTurn(TurnRole.system, [TextPart(system)]));
  } else if (system is List) {
    final text = system
        .whereType<Map<String, dynamic>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String?)
        .where((t) => t != null && t.isNotEmpty)
        .join('\n');
    if (text.isNotEmpty) {
      turns.add(BeautifiedTurn(TurnRole.system, [TextPart(text)]));
    }
  }

  final messages = body['messages'] as List<dynamic>? ?? const [];
  for (final msg in messages) {
    if (msg is! Map<String, dynamic>) continue;
    final role = _normalizeRole(msg['role'] as String?);
    final parts = <TurnPart>[];

    final content = msg['content'];
    if (content is String && content.isNotEmpty) {
      parts.add(TextPart(content));
    } else if (content is List) {
      for (final block in content) {
        if (block is! Map<String, dynamic>) continue;
        final p = _parseClaudeContentBlock(block);
        if (p != null) parts.add(p);
      }
    }

    if (parts.isNotEmpty) turns.add(BeautifiedTurn(role, parts));
  }

  return BeautifiedBody(
    turns,
    _remainingJson(body, const {'messages', 'system'}),
  );
}

BeautifiedBody _parseGemini(Map<String, dynamic> body) {
  final turns = <BeautifiedTurn>[];

  // Gemini system instruction is a top-level object with parts.
  final sysInstr = body['systemInstruction'];
  if (sysInstr is Map<String, dynamic>) {
    final text = _extractGeminiText(sysInstr['parts']);
    if (text.isNotEmpty) {
      turns.add(BeautifiedTurn(TurnRole.system, [TextPart(text)]));
    }
  }

  final contents = body['contents'] as List<dynamic>? ?? const [];
  for (final entry in contents) {
    if (entry is! Map<String, dynamic>) continue;
    final role = _normalizeRole(entry['role'] as String?);
    final parts = <TurnPart>[];

    final partsList = entry['parts'] as List<dynamic>? ?? const [];
    for (final part in partsList) {
      if (part is! Map<String, dynamic>) continue;
      final p = _parseGeminiPart(part);
      if (p != null) parts.add(p);
    }

    if (parts.isNotEmpty) turns.add(BeautifiedTurn(role, parts));
  }

  return BeautifiedBody(
    turns,
    _remainingJson(body, const {'contents', 'systemInstruction'}),
  );
}

BeautifiedBody _parseOpenAIResponses(Map<String, dynamic> body) {
  final turns = <BeautifiedTurn>[];

  // OpenAI Responses: system prompt is a top-level "instructions" string.
  final instructions = body['instructions'];
  if (instructions is String && instructions.isNotEmpty) {
    turns.add(BeautifiedTurn(TurnRole.system, [TextPart(instructions)]));
  }

  // "input" can be a simple string or an array of items.
  final input = body['input'];
  if (input is String && input.isNotEmpty) {
    turns.add(BeautifiedTurn(TurnRole.user, [TextPart(input)]));
  } else if (input is List) {
    for (final item in input) {
      if (item is! Map<String, dynamic>) continue;
      final type = item['type'] as String?;

      if (type == 'function_call') {
        turns.add(
          BeautifiedTurn(TurnRole.assistant, [
            ToolCallPart(
              (item['name'] as String?) ?? 'unknown',
              _prettyOrRaw(item['arguments']),
            ),
          ]),
        );
        continue;
      }
      if (type == 'function_call_output') {
        final output = item['output'];
        if (output is List) {
          // Content-parts array (image-bearing function outputs).
          final texts = <String>[];
          final mediaParts = <TurnPart>[];
          for (final part in output) {
            if (part is! Map<String, dynamic>) continue;
            final p = _parseOpenAIResponsesContentPart(part);
            if (p is TextPart) {
              texts.add(p.text);
            } else if (p != null) {
              mediaParts.add(p);
            }
          }
          final parts = <TurnPart>[];
          if (texts.isNotEmpty) {
            parts.add(
              ToolResultPart(
                (item['call_id'] as String?) ?? 'tool',
                texts.join('\n'),
              ),
            );
          }
          parts.addAll(mediaParts);
          if (parts.isNotEmpty) {
            turns.add(BeautifiedTurn(TurnRole.tool, parts));
          }
        } else {
          turns.add(
            BeautifiedTurn(TurnRole.tool, [
              ToolResultPart(
                (item['call_id'] as String?) ?? 'tool',
                _prettyOrRaw(output),
              ),
            ]),
          );
        }
        continue;
      }

      // Message item: has role + content.
      final role = _normalizeRole(item['role'] as String?);
      final parts = <TurnPart>[];
      final content = item['content'];
      if (content is String && content.isNotEmpty) {
        parts.add(TextPart(content));
      } else if (content is List) {
        for (final part in content) {
          if (part is! Map<String, dynamic>) continue;
          final p = _parseOpenAIResponsesContentPart(part);
          if (p != null) parts.add(p);
        }
      }

      // Vendor-echoed reasoning (OpenRouter-style reasoning_details).
      final reasoningDetails = item['reasoning_details'];
      if (reasoningDetails is List) {
        final text = reasoningDetails
            .whereType<Map<String, dynamic>>()
            .map((d) => d['text'] as String?)
            .where((t) => t != null && t.isNotEmpty)
            .join();
        if (text.isNotEmpty) parts.add(ThinkingPart(text));
      }

      if (parts.isNotEmpty) turns.add(BeautifiedTurn(role, parts));
    }
  }

  return BeautifiedBody(
    turns,
    _remainingJson(body, const {'input', 'instructions'}),
  );
}

// ---------------------------------------------------------------------------
// Content-part parsers (per protocol)
// ---------------------------------------------------------------------------

TurnPart? _parseOpenAIChatContentPart(Map<String, dynamic> part) {
  switch (part['type'] as String?) {
    case 'text':
      final t = part['text'] as String?;
      if (t != null && t.isNotEmpty) return TextPart(t);
      return null;
    case 'image_url':
      final url = (part['image_url'] as Map<String, dynamic>?)?['url'];
      if (url is String) {
        if (url.startsWith('data:')) {
          final info = _parseDataUrl(url);
          return ImagePart(
            mime: info?.mime,
            isBase64: true,
            byteLength: info?.byteLength ?? 0,
          );
        }
        return ImagePart(url: url);
      }
      return null;
    case 'video_url':
      final url = (part['video_url'] as Map<String, dynamic>?)?['url'];
      if (url is String && url.startsWith('data:')) {
        final info = _parseDataUrl(url);
        return ImagePart(
          mime: info?.mime,
          isBase64: true,
          byteLength: info?.byteLength ?? 0,
        );
      }
      return ImagePart(url: url is String ? url : null);
    case 'file':
      final file = part['file'] as Map<String, dynamic>?;
      final filename = (file?['filename'] as String?) ?? 'file';
      return FilePart(filename);
    default:
      return null;
  }
}

TurnPart? _parseClaudeContentBlock(Map<String, dynamic> block) {
  switch (block['type'] as String?) {
    case 'text':
      final t = block['text'] as String?;
      if (t != null && t.isNotEmpty) return TextPart(t);
      return null;
    case 'image':
      final source = block['source'] as Map<String, dynamic>?;
      final mediaType = (source?['media_type'] as String?) ?? 'image';
      final data = source?['data'] as String?;
      return ImagePart(
        mime: mediaType,
        isBase64: true,
        byteLength: data != null ? _base64ByteLength(data) : 0,
      );
    case 'tool_use':
      return ToolCallPart(
        (block['name'] as String?) ?? 'unknown',
        _prettyOrRaw(block['input']),
      );
    case 'tool_result':
      final content = block['content'];
      if (content is String) {
        return ToolResultPart(
          (block['tool_use_id'] as String?) ?? 'tool',
          content,
        );
      }
      if (content is List) {
        // Nested content blocks: extract text, summarize non-text.
        final texts = <String>[];
        for (final sub in content) {
          if (sub is! Map<String, dynamic>) continue;
          if (sub['type'] == 'text' && sub['text'] is String) {
            texts.add(sub['text'] as String);
          } else if (sub['type'] == 'image') {
            final source = sub['source'] as Map<String, dynamic>?;
            final mediaType = (source?['media_type'] as String?) ?? 'image';
            final data = source?['data'] as String?;
            final label = ImagePart(
              mime: mediaType,
              isBase64: true,
              byteLength: data != null ? _base64ByteLength(data) : 0,
            ).displayLabel;
            texts.add('[$label]');
          } else {
            texts.add('[${sub['type'] ?? 'block'}]');
          }
        }
        return ToolResultPart(
          (block['tool_use_id'] as String?) ?? 'tool',
          texts.join('\n'),
        );
      }
      return ToolResultPart(
        (block['tool_use_id'] as String?) ?? 'tool',
        _prettyOrRaw(content),
      );
    case 'thinking':
      final t = block['thinking'] as String?;
      if (t != null && t.isNotEmpty) return ThinkingPart(t);
      return null;
    case 'redacted_thinking':
      final data = block['data'] as String?;
      return RedactedThinkingPart(data != null ? _base64ByteLength(data) : 0);
    default:
      return null;
  }
}

TurnPart? _parseGeminiPart(Map<String, dynamic> part) {
  // Text part.
  if (part['text'] is String) {
    final t = part['text'] as String;
    if (t.isNotEmpty) return TextPart(t);
    return null;
  }
  // Inline data (base64).
  final inlineData = part['inline_data'] as Map<String, dynamic>?;
  if (inlineData != null) {
    final mime = (inlineData['mime_type'] as String?) ?? 'data';
    final data = inlineData['data'] as String?;
    return ImagePart(
      mime: mime,
      isBase64: true,
      byteLength: data != null ? _base64ByteLength(data) : 0,
    );
  }
  // File data (URI reference).
  final fileData = part['file_data'] as Map<String, dynamic>?;
  if (fileData != null) {
    final uri = (fileData['file_uri'] as String?) ?? 'file';
    return FilePart(uri);
  }
  // Function call (model turn).
  final fnCall = part['functionCall'] as Map<String, dynamic>?;
  if (fnCall != null) {
    return ToolCallPart(
      (fnCall['name'] as String?) ?? 'unknown',
      _prettyOrRaw(fnCall['args']),
    );
  }
  // Function response (user turn).
  final fnResp = part['functionResponse'] as Map<String, dynamic>?;
  if (fnResp != null) {
    return ToolResultPart(
      (fnResp['name'] as String?) ?? 'tool',
      _prettyOrRaw(fnResp['response']),
    );
  }
  return null;
}

TurnPart? _parseOpenAIResponsesContentPart(Map<String, dynamic> part) {
  switch (part['type'] as String?) {
    case 'input_text':
    case 'output_text':
      final t = part['text'] as String?;
      if (t != null && t.isNotEmpty) return TextPart(t);
      return null;
    case 'input_image':
      final url = part['image_url'] as String?;
      if (url != null && url.startsWith('data:')) {
        final info = _parseDataUrl(url);
        return ImagePart(
          mime: info?.mime,
          isBase64: true,
          byteLength: info?.byteLength ?? 0,
        );
      }
      return ImagePart(url: url);
    case 'input_file':
      final filename = (part['filename'] as String?) ?? 'file';
      return FilePart(filename);
    default:
      return null;
  }
}

String _extractGeminiText(dynamic parts) {
  if (parts is! List) return '';
  return parts
      .whereType<Map<String, dynamic>>()
      .map((p) => p['text'] as String?)
      .where((t) => t != null && t.isNotEmpty)
      .join('\n');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

TurnRole _normalizeRole(String? role) {
  switch (role) {
    case 'system':
    case 'developer':
      return TurnRole.system;
    case 'user':
      return TurnRole.user;
    case 'assistant':
    case 'model':
      return TurnRole.assistant;
    case 'tool':
    case 'function':
      return TurnRole.tool;
    default:
      return TurnRole.user;
  }
}

/// Pretty-prints a JSON value. If [value] is a JSON string (stringified JSON),
/// it is decoded first. Falls back to the raw string representation.
String _prettyOrRaw(dynamic value) {
  if (value == null) return '';
  if (value is String) {
    if (value.isEmpty) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(value));
    } catch (_) {
      return value;
    }
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}

/// Builds a pretty-printed JSON string of all non-message fields.
String _remainingJson(Map<String, dynamic> body, Set<String> messageKeys) {
  final config = Map<String, dynamic>.from(body)
    ..removeWhere((k, _) => messageKeys.contains(k));
  if (config.isEmpty) return '';
  return const JsonEncoder.withIndent('  ').convert(config);
}

/// Parses a data: URL into structured image metadata.
({String mime, int byteLength})? _parseDataUrl(String dataUrl) {
  final commaIdx = dataUrl.indexOf(',');
  if (commaIdx < 0) return null;
  final header = dataUrl.substring(0, commaIdx);
  final mimeMatch = RegExp(r'^data:([^;,]+)').firstMatch(header);
  final mime = mimeMatch?.group(1) ?? 'data';
  if (!header.contains('base64')) return (mime: mime, byteLength: 0);
  final payload = dataUrl.substring(commaIdx + 1);
  return (mime: mime, byteLength: _base64ByteLength(payload));
}

/// Estimates the decoded byte length of a base64 string.
int _base64ByteLength(String base64Str) {
  final cleaned = base64Str.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
  if (cleaned.isEmpty) return 0;
  final padding = '=' * (cleaned.length % 4 == 0 ? 0 : 4 - cleaned.length % 4);
  try {
    return base64.decode(cleaned + padding).length;
  } catch (_) {
    // Fallback estimate: 3 bytes per 4 base64 chars.
    return (cleaned.length * 3 ~/ 4).clamp(0, 99999999);
  }
}

/// Human-readable byte size.
String _describeBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
