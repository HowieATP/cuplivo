import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/features/settings/logs/request_body_beautifier.dart';

void main() {
  group('tryBeautify', () {
    group('failure cases', () {
      test('returns null for empty string', () {
        expect(tryBeautify(''), isNull);
        expect(tryBeautify('   '), isNull);
      });

      test('returns null for invalid JSON', () {
        expect(tryBeautify('not json'), isNull);
        expect(tryBeautify('{broken'), isNull);
        expect(tryBeautify('base64: SGVsbG8='), isNull);
      });

      test('returns null for JSON that is not an object', () {
        expect(tryBeautify('[1, 2, 3]'), isNull);
        expect(tryBeautify('"hello"'), isNull);
        expect(tryBeautify('42'), isNull);
      });

      test('returns null for unknown protocol structure', () {
        expect(tryBeautify('{"foo": "bar", "baz": [1, 2]}'), isNull);
      });
    });

    group('OpenAI Chat Completions', () {
      test('parses system + user + assistant with text content', () {
        final body = jsonEncode({
          'model': 'gpt-4o',
          'messages': [
            {'role': 'system', 'content': 'You are helpful.'},
            {'role': 'user', 'content': 'Hello'},
            {'role': 'assistant', 'content': 'Hi there!'},
          ],
          'temperature': 0.7,
          'stream': true,
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 3);

        expect(result.turns[0].role, TurnRole.system);
        expect((result.turns[0].parts[0] as TextPart).text, 'You are helpful.');

        expect(result.turns[1].role, TurnRole.user);
        expect((result.turns[1].parts[0] as TextPart).text, 'Hello');

        expect(result.turns[2].role, TurnRole.assistant);
        expect((result.turns[2].parts[0] as TextPart).text, 'Hi there!');

        final config = jsonDecode(result.configJson) as Map<String, dynamic>;
        expect(config['model'], 'gpt-4o');
        expect(config['temperature'], 0.7);
        expect(config['stream'], true);
        expect(config.containsKey('messages'), isFalse);
      });

      test('parses tool_calls with stringified JSON arguments', () {
        final body = jsonEncode({
          'model': 'gpt-4o',
          'messages': [
            {'role': 'user', 'content': 'What is the weather?'},
            {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'get_weather',
                    'arguments': '{"city": "Beijing"}',
                  },
                },
              ],
            },
            {
              'role': 'tool',
              'tool_call_id': 'call_1',
              'name': 'get_weather',
              'content': '{"temp": 22}',
            },
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 3);

        // Assistant turn with tool_call part.
        final assistantParts = result.turns[1].parts;
        expect(assistantParts.length, 1);
        final toolCall = assistantParts[0] as ToolCallPart;
        expect(toolCall.name, 'get_weather');
        expect(toolCall.arguments, contains('Beijing'));

        // Tool turn with tool_result part.
        final toolParts = result.turns[2].parts;
        expect(toolParts.length, 1);
        final toolResult = toolParts[0] as ToolResultPart;
        expect(toolResult.name, 'get_weather');
        expect(toolResult.output, contains('22'));
      });

      test('parses multipart content with image_url', () {
        final body = jsonEncode({
          'model': 'gpt-4o',
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'What is this?'},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'https://example.com/img.png'},
                },
              ],
            },
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 1);
        expect(result.turns[0].role, TurnRole.user);
        expect(result.turns[0].parts.length, 2);
        expect((result.turns[0].parts[0] as TextPart).text, 'What is this?');
        final img = result.turns[0].parts[1] as ImagePart;
        expect(img.url, 'https://example.com/img.png');
        expect(img.isBase64, isFalse);
      });

      test('handles data: URL image', () {
        final body = jsonEncode({
          'messages': [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'Look'},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/png;base64,SGVsbG8='},
                },
              ],
            },
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        final imagePart = result!.turns[0].parts[1] as ImagePart;
        expect(imagePart.isBase64, isTrue);
        expect(imagePart.mime, 'image/png');
        expect(imagePart.displayLabel, contains('image/png'));
        expect(imagePart.displayLabel, contains('(base64)'));
        expect(imagePart.displayLabel, contains('B'));
      });
    });

    group('Claude', () {
      test('parses system string + messages with text blocks', () {
        final body = jsonEncode({
          'model': 'claude-3',
          'max_tokens': 1024,
          'system': 'You are Claude.',
          'messages': [
            {'role': 'user', 'content': 'Hi'},
            {'role': 'assistant', 'content': 'Hello!'},
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 3);

        expect(result.turns[0].role, TurnRole.system);
        expect((result.turns[0].parts[0] as TextPart).text, 'You are Claude.');

        expect(result.turns[1].role, TurnRole.user);
        expect((result.turns[1].parts[0] as TextPart).text, 'Hi');

        expect(result.turns[2].role, TurnRole.assistant);

        final config = jsonDecode(result.configJson) as Map<String, dynamic>;
        expect(config['model'], 'claude-3');
        expect(config['max_tokens'], 1024);
        expect(config.containsKey('system'), isFalse);
        expect(config.containsKey('messages'), isFalse);
      });

      test('parses tool_use and tool_result blocks', () {
        final body = jsonEncode({
          'model': 'claude-3',
          'max_tokens': 1024,
          'system': 'You are Claude.',
          'messages': [
            {'role': 'user', 'content': 'What is the weather?'},
            {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': 'Let me check.'},
                {
                  'type': 'tool_use',
                  'id': 'toolu_1',
                  'name': 'get_weather',
                  'input': {'city': 'Beijing'},
                },
              ],
            },
            {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': 'toolu_1',
                  'content': 'Sunny, 22C',
                },
              ],
            },
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 4); // system + user + assistant + user

        final assistantParts = result.turns[2].parts;
        expect(assistantParts.length, 2);
        expect(assistantParts[0] is TextPart, isTrue);
        expect(assistantParts[1] is ToolCallPart, isTrue);

        final userParts = result.turns[3].parts;
        expect(userParts.length, 1);
        expect(userParts[0] is ToolResultPart, isTrue);
        final toolResult = userParts[0] as ToolResultPart;
        expect(toolResult.output, 'Sunny, 22C');
      });

      test('parses thinking and redacted_thinking blocks', () {
        final body = jsonEncode({
          'model': 'claude-3',
          'max_tokens': 1024,
          'system': 'You are Claude.',
          'messages': [
            {
              'role': 'assistant',
              'content': [
                {'type': 'thinking', 'thinking': 'I should...'},
                {'type': 'redacted_thinking', 'data': 'SGVsbG8='},
                {'type': 'text', 'text': 'Here is my answer.'},
              ],
            },
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 2); // system + assistant

        final parts = result.turns[1].parts;
        expect(parts.length, 3);
        expect(parts[0] is ThinkingPart, isTrue);
        expect(parts[1] is RedactedThinkingPart, isTrue);
        expect(parts[2] is TextPart, isTrue);
      });

      test('handles system as list of blocks', () {
        final body = jsonEncode({
          'model': 'claude-3',
          'max_tokens': 1024,
          'system': [
            {'type': 'text', 'text': 'System rule 1.'},
            {'type': 'text', 'text': 'System rule 2.'},
          ],
          'messages': [],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 1);
        expect(result.turns[0].role, TurnRole.system);
        expect(
          (result.turns[0].parts[0] as TextPart).text,
          'System rule 1.\nSystem rule 2.',
        );
      });
    });

    group('Gemini', () {
      test('parses systemInstruction + contents with text parts', () {
        final body = jsonEncode({
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': 'Hello'},
              ],
            },
            {
              'role': 'model',
              'parts': [
                {'text': 'Hi!'},
              ],
            },
          ],
          'systemInstruction': {
            'parts': [
              {'text': 'Be helpful.'},
            ],
          },
          'generationConfig': {'temperature': 0.7},
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 3);

        expect(result.turns[0].role, TurnRole.system);
        expect((result.turns[0].parts[0] as TextPart).text, 'Be helpful.');

        expect(result.turns[1].role, TurnRole.user);
        expect(result.turns[2].role, TurnRole.assistant);

        final config = jsonDecode(result.configJson) as Map<String, dynamic>;
        expect(config.containsKey('generationConfig'), isTrue);
        expect(config.containsKey('contents'), isFalse);
        expect(config.containsKey('systemInstruction'), isFalse);
      });

      test('parses functionCall and functionResponse parts', () {
        final body = jsonEncode({
          'contents': [
            {
              'role': 'model',
              'parts': [
                {'text': 'Let me check.'},
                {
                  'functionCall': {
                    'name': 'get_weather',
                    'args': {'city': 'Beijing'},
                  },
                },
              ],
            },
            {
              'role': 'user',
              'parts': [
                {
                  'functionResponse': {
                    'name': 'get_weather',
                    'response': {'temp': 22},
                  },
                },
              ],
            },
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 2);

        final modelParts = result.turns[0].parts;
        expect(modelParts.length, 2);
        expect(modelParts[0] is TextPart, isTrue);
        expect(modelParts[1] is ToolCallPart, isTrue);

        final userParts = result.turns[1].parts;
        expect(userParts.length, 1);
        expect(userParts[0] is ToolResultPart, isTrue);
      });

      test('handles inline_data with size estimation', () {
        // 12 bytes -> base64 of "Hello World!" = SGVsbG8gV29ybGQh
        final body = jsonEncode({
          'contents': [
            {
              'role': 'user',
              'parts': [
                {
                  'inline_data': {
                    'mime_type': 'image/png',
                    'data': 'SGVsbG8gV29ybGQh',
                  },
                },
              ],
            },
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        final imagePart = result!.turns[0].parts[0] as ImagePart;
        expect(imagePart.isBase64, isTrue);
        expect(imagePart.mime, 'image/png');
        expect(imagePart.displayLabel, contains('image/png'));
        expect(imagePart.displayLabel, contains('(base64)'));
        expect(imagePart.displayLabel, contains('B'));
      });
    });

    group('OpenAI Responses', () {
      test('parses instructions + input as array', () {
        final body = jsonEncode({
          'model': 'gpt-4o',
          'instructions': 'You are helpful.',
          'input': [
            {
              'role': 'user',
              'content': [
                {'type': 'input_text', 'text': 'Hello'},
              ],
            },
            {
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': 'Hi!'},
              ],
            },
          ],
          'temperature': 0.7,
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 3);

        expect(result.turns[0].role, TurnRole.system);
        expect((result.turns[0].parts[0] as TextPart).text, 'You are helpful.');

        expect(result.turns[1].role, TurnRole.user);
        expect(result.turns[2].role, TurnRole.assistant);

        final config = jsonDecode(result.configJson) as Map<String, dynamic>;
        expect(config['model'], 'gpt-4o');
        expect(config.containsKey('input'), isFalse);
        expect(config.containsKey('instructions'), isFalse);
      });

      test('parses input as simple string', () {
        final body = jsonEncode({
          'model': 'gpt-4o',
          'input': 'Just a simple prompt',
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 1);
        expect(result.turns[0].role, TurnRole.user);
        expect(
          (result.turns[0].parts[0] as TextPart).text,
          'Just a simple prompt',
        );
      });

      test('parses function_call and function_call_output items', () {
        final body = jsonEncode({
          'model': 'gpt-4o',
          'input': [
            {'role': 'user', 'content': 'What is the weather?'},
            {
              'type': 'function_call',
              'call_id': 'call_1',
              'name': 'get_weather',
              'arguments': '{"city": "Beijing"}',
            },
            {
              'type': 'function_call_output',
              'call_id': 'call_1',
              'output': '{"temp": 22}',
            },
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 3);

        expect(result.turns[0].role, TurnRole.user);
        expect(result.turns[1].role, TurnRole.assistant);
        expect(result.turns[2].role, TurnRole.tool);

        expect(result.turns[1].parts[0] is ToolCallPart, isTrue);
        expect(result.turns[2].parts[0] is ToolResultPart, isTrue);
      });
    });

    group('edge cases', () {
      test('empty messages array produces empty turns', () {
        final body = jsonEncode({
          'model': 'gpt-4o',
          'messages': [],
          'temperature': 0.7,
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns, isEmpty);
        expect(result.configJson, isNotEmpty);
      });

      test('malformed messages entries are skipped', () {
        final body = jsonEncode({
          'model': 'gpt-4o',
          'messages': [
            'not a map',
            {'role': 'user', 'content': 'valid'},
            42,
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 1);
        expect(result.turns[0].role, TurnRole.user);
      });

      test(
        'Claude without system is detected as Claude if system key absent',
        () {
          // When Claude has no system prompt, "system" key may be omitted.
          // This should fall through to OpenAI Chat detection.
          final body = jsonEncode({
            'model': 'claude-3',
            'max_tokens': 1024,
            'messages': [
              {'role': 'user', 'content': 'Hi'},
              {'role': 'assistant', 'content': 'Hello!'},
            ],
          });

          final result = tryBeautify(body);
          expect(result, isNotNull);
          // Detected as OpenAI Chat (fallback), which is fine - both use
          // "messages" and the rendering is the same.
          expect(result!.turns.length, 2);
        },
      );

      test('config JSON is empty when only message fields present', () {
        final body = jsonEncode({
          'messages': [
            {'role': 'user', 'content': 'Hi'},
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 1);
        expect(result.configJson, isEmpty);
      });

      test('developer role is mapped to system', () {
        final body = jsonEncode({
          'messages': [
            {'role': 'developer', 'content': 'You are a coding expert.'},
            {'role': 'user', 'content': 'Write a function'},
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 2);
        expect(result.turns[0].role, TurnRole.system);
        expect(
          (result.turns[0].parts[0] as TextPart).text,
          'You are a coding expert.',
        );
      });

      test('reasoning_details list is concatenated into ThinkingPart', () {
        final body = jsonEncode({
          'messages': [
            {'role': 'user', 'content': 'Hi'},
            {
              'role': 'assistant',
              'content': '\n\n',
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'search_web',
                    'arguments': '{"query":"test"}',
                  },
                },
              ],
              'reasoning_details': [
                {
                  'type': 'reasoning.text',
                  'text': '思考',
                  'format': 'unknown',
                  'index': 0,
                },
                {
                  'type': 'reasoning.text',
                  'text': '过程',
                  'format': 'unknown',
                  'index': 0,
                },
              ],
            },
          ],
        });

        final result = tryBeautify(body);
        expect(result, isNotNull);
        expect(result!.turns.length, 2);

        final assistantParts = result.turns[1].parts;
        // Expect: ToolCallPart + ThinkingPart (order: tool_calls first, then reasoning).
        final thinking = assistantParts.whereType<ThinkingPart>().toList();
        expect(thinking.length, 1);
        expect(thinking[0].content, '思考过程');
      });
    });
  });
}
