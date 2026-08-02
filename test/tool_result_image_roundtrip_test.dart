import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

ProviderConfig _openAiConfig(String baseUrl, {bool? toolResultImages}) {
  return ProviderConfig(
    id: 'OpenAITest',
    enabled: true,
    name: 'OpenAITest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.openai,
    useResponseApi: false,
    enableToolResultImages: toolResultImages,
  );
}

ProviderConfig _responsesConfig(String baseUrl, {bool? toolResultImages}) {
  return _openAiConfig(
    baseUrl,
    toolResultImages: toolResultImages,
  ).copyWith(useResponseApi: true);
}

ProviderConfig _claudeConfig(String baseUrl) {
  return ProviderConfig(
    id: 'ClaudeTest',
    enabled: true,
    name: 'ClaudeTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.claude,
  );
}

Future<Map<String, String>> _tempImageFile() async {
  final dir = await Directory.systemTemp.createTemp('cuplivo_rt_img_');
  addTearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });
  final file = File('${dir.path}/tool.png');
  await file.writeAsBytes(const [1, 2, 3, 4]);
  return {'path': file.path, 'dataUrl': 'data:image/png;base64,AQIDBA=='};
}

void main() {
  group('tool result image round-trip', () {
    group('Chat Completions', () {
      test('live loop: tool result image becomes content parts', () async {
        final img = await _tempImageFile();
        final requestBodies = await _captureChatToolLoop((baseUrl) {
          return ChatApiService.sendMessageStream(
            config: _openAiConfig(baseUrl, toolResultImages: true),
            modelId: 'gpt-4.1',
            messages: const [
              {'role': 'user', 'content': 'inspect'},
            ],
            tools: const [_lookupTool],
            onToolCall: (_, __, {toolCallId}) async =>
                'result\n[image:${img['path']}]',
            stream: false,
          ).toList();
        });

        expect(requestBodies, hasLength(2));
        final toolMessage = _toolMessageOf(requestBodies[1]);
        final content = toolMessage['content'] as List;
        expect(content, hasLength(2));
        expect(content.first, {'type': 'text', 'text': 'result'});
        expect(content.last, {
          'type': 'image_url',
          'image_url': {'url': img['dataUrl']},
        });
      });

      test('history replay: stored markers become content parts', () async {
        final img = await _tempImageFile();
        final body = await _captureChatBody((baseUrl) {
          return ChatApiService.sendMessageStream(
            config: _openAiConfig(baseUrl, toolResultImages: true),
            modelId: 'gpt-4.1',
            messages: [
              {'role': 'user', 'content': 'hi'},
              {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'id': 'call_1',
                    'type': 'function',
                    'function': {'name': 'lookup', 'arguments': '{}'},
                  },
                ],
              },
              {
                'role': 'tool',
                'tool_call_id': 'call_1',
                'content': 'result [image:${img['path']}]',
              },
              {'role': 'user', 'content': 'continue'},
            ],
            stream: false,
          ).toList();
        });

        final toolMessage = _toolMessageOf(body);
        final content = toolMessage['content'] as List;
        expect(content, hasLength(2));
        expect(content.first, {'type': 'text', 'text': 'result'});
        expect(content.last, {
          'type': 'image_url',
          'image_url': {'url': img['dataUrl']},
        });
      });

      test('no markers: tool message content stays a plain string', () async {
        final requestBodies = await _captureChatToolLoop((baseUrl) {
          return ChatApiService.sendMessageStream(
            config: _openAiConfig(baseUrl, toolResultImages: true),
            modelId: 'gpt-4.1',
            messages: const [
              {'role': 'user', 'content': 'inspect'},
            ],
            tools: const [_lookupTool],
            onToolCall: (_, __, {toolCallId}) async => 'metadata',
            stream: false,
          ).toList();
        });

        expect(requestBodies, hasLength(2));
        final toolMessage = _toolMessageOf(requestBodies[1]);
        expect(toolMessage['content'], 'metadata');
        expect(toolMessage['content'], isA<String>());
      });

      test('allowlist off: markers stay literal text', () async {
        final img = await _tempImageFile();
        final requestBodies = await _captureChatToolLoop((baseUrl) {
          return ChatApiService.sendMessageStream(
            config: _openAiConfig(baseUrl),
            modelId: 'gpt-4.1',
            messages: const [
              {'role': 'user', 'content': 'inspect'},
            ],
            tools: const [_lookupTool],
            onToolCall: (_, __, {toolCallId}) async =>
                'result [image:${img['path']}]',
            stream: false,
          ).toList();
        });

        expect(requestBodies, hasLength(2));
        final toolMessage = _toolMessageOf(requestBodies[1]);
        expect(toolMessage['content'], isA<String>());
        expect(
          (toolMessage['content'] as String),
          contains('[image:${img['path']}]'),
        );
      });

      test('explicit off overrides allowlist membership', () async {
        final img = await _tempImageFile();
        final body = await _captureChatBody((baseUrl) {
          return ChatApiService.sendMessageStream(
            config: _openAiConfig(baseUrl, toolResultImages: false),
            modelId: 'gpt-4.1',
            messages: [
              {
                'role': 'tool',
                'tool_call_id': 'call_1',
                'content': 'result [image:${img['path']}]',
              },
            ],
            stream: false,
          ).toList();
        });

        final toolMessage = _toolMessageOf(body);
        expect(toolMessage['content'], isA<String>());
      });

      test(
        'Kimi K3: local image becomes part, remote URL stays text',
        () async {
          final img = await _tempImageFile();
          final body = await _captureChatBody((baseUrl) {
            return ChatApiService.sendMessageStream(
              config: _openAiConfig(baseUrl, toolResultImages: true).copyWith(
                modelOverrides: {
                  'kimi-k3': {
                    'input': ['text', 'image'],
                    'output': ['text'],
                  },
                },
              ),
              modelId: 'kimi-k3',
              messages: [
                {
                  'role': 'tool',
                  'tool_call_id': 'call_1',
                  'content':
                      'result [image:https://example.com/remote.png] '
                      '[image:${img['path']}]',
                },
              ],
              stream: false,
            ).toList();
          });

          final toolMessage = _toolMessageOf(body);
          final content = toolMessage['content'] as List;
          expect(content, hasLength(2));
          expect(content.first['type'], 'text');
          expect(
            (content.first['text'] as String),
            contains('[image:https://example.com/remote.png]'),
          );
          expect(content.last, {
            'type': 'image_url',
            'image_url': {'url': img['dataUrl']},
          });
        },
      );

      test(
        'text-only model: remote URL kept as bare text, local dropped',
        () async {
          final img = await _tempImageFile();
          final body = await _captureChatBody((baseUrl) {
            return ChatApiService.sendMessageStream(
              config: _openAiConfig(baseUrl),
              modelId: 'mimo-v2.5-pro',
              messages: [
                {
                  'role': 'tool',
                  'tool_call_id': 'call_1',
                  'content':
                      'search [image:https://example.com/photo.png] '
                      '[image:${img['path']}]',
                },
              ],
              stream: false,
            ).toList();
          });

          final toolMessage = _toolMessageOf(body);
          expect(toolMessage['content'], isA<String>());
          expect(
            toolMessage['content'],
            'search https://example.com/photo.png',
          );
        },
      );
    });

    group('Responses API', () {
      test(
        'live loop: function_call_output output becomes parts array',
        () async {
          final img = await _tempImageFile();
          final requestBodies = await _captureResponsesToolLoop((baseUrl) {
            return ChatApiService.sendMessageStream(
              config: _responsesConfig(baseUrl, toolResultImages: true),
              modelId: 'gpt-4.1',
              messages: const [
                {'role': 'user', 'content': 'inspect'},
              ],
              tools: const [_lookupTool],
              onToolCall: (_, __, {toolCallId}) async =>
                  'result [image:${img['path']}]',
            ).toList();
          });

          expect(requestBodies, hasLength(2));
          final outputItem = _functionCallOutputOf(requestBodies[1]);
          expect(outputItem['output'], isA<List>());
          final output = outputItem['output'] as List;
          expect(output, hasLength(2));
          expect(output.first, {'type': 'input_text', 'text': 'result'});
          expect(output.last, {
            'type': 'input_image',
            'image_url': img['dataUrl'],
          });
        },
      );

      test(
        'history replay: function_call_output output becomes parts array',
        () async {
          final img = await _tempImageFile();
          final body = await _captureResponsesBody((baseUrl) {
            return ChatApiService.sendMessageStream(
              config: _responsesConfig(baseUrl, toolResultImages: true),
              modelId: 'gpt-4.1',
              messages: [
                {
                  'role': 'tool',
                  'tool_call_id': 'call_1',
                  'content': 'result [image:${img['path']}]',
                },
              ],
            ).toList();
          });

          final outputItem = _functionCallOutputOf(body);
          expect(outputItem['output'], isA<List>());
          final output = outputItem['output'] as List;
          expect(output, hasLength(2));
          expect(output.first, {'type': 'input_text', 'text': 'result'});
          expect(output.last, {
            'type': 'input_image',
            'image_url': img['dataUrl'],
          });
        },
      );

      test('no markers: output stays a plain string', () async {
        final requestBodies = await _captureResponsesToolLoop((baseUrl) {
          return ChatApiService.sendMessageStream(
            config: _responsesConfig(baseUrl, toolResultImages: true),
            modelId: 'gpt-4.1',
            messages: const [
              {'role': 'user', 'content': 'inspect'},
            ],
            tools: const [_lookupTool],
            onToolCall: (_, __, {toolCallId}) async => 'metadata',
          ).toList();
        });

        expect(requestBodies, hasLength(2));
        final outputItem = _functionCallOutputOf(requestBodies[1]);
        expect(outputItem['output'], 'metadata');
      });
    });

    group('Claude', () {
      test('history replay: tool_result content becomes blocks', () async {
        final img = await _tempImageFile();
        final body = await _captureClaudeBody((baseUrl) {
          return ChatApiService.sendMessageStream(
            config: _claudeConfig(baseUrl),
            modelId: 'claude-sonnet-5',
            messages: [
              {'role': 'user', 'content': 'hi'},
              {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'id': 'toolu_1',
                    'type': 'function',
                    'function': {'name': 'lookup', 'arguments': '{}'},
                  },
                ],
              },
              {
                'role': 'tool',
                'tool_call_id': 'toolu_1',
                'content': 'result [image:${img['path']}]',
              },
            ],
            stream: false,
          ).toList();
        });

        final toolResult = _claudeToolResultOf(body);
        expect(toolResult['content'], isA<List>());
        final blocks = toolResult['content'] as List;
        expect(blocks, hasLength(2));
        expect(blocks.first, {'type': 'text', 'text': 'result'});
        expect(blocks.last['type'], 'image');
        expect(blocks.last['source'], {
          'type': 'base64',
          'media_type': 'image/png',
          'data': 'AQIDBA==',
        });
      });

      test(
        'non-streaming live loop: tool_result content becomes blocks',
        () async {
          final img = await _tempImageFile();
          final requestBodies = await _captureClaudeToolLoop(
            stream: false,
            sendRequest: (baseUrl) {
              return ChatApiService.sendMessageStream(
                config: _claudeConfig(baseUrl),
                modelId: 'claude-sonnet-5',
                messages: const [
                  {'role': 'user', 'content': 'inspect'},
                ],
                tools: const [_lookupTool],
                onToolCall: (_, __, {toolCallId}) async =>
                    'result\n[image:${img['path']}]',
                stream: false,
              ).toList();
            },
          );

          expect(requestBodies, hasLength(2));
          final toolResult = _claudeToolResultOf(requestBodies[1]);
          expect(toolResult['content'], isA<List>());
          final blocks = toolResult['content'] as List;
          expect(blocks, hasLength(2));
          expect(blocks.first, {'type': 'text', 'text': 'result'});
          expect(blocks.last['source'], {
            'type': 'base64',
            'media_type': 'image/png',
            'data': 'AQIDBA==',
          });
        },
      );

      test('streaming live loop: tool_result content becomes blocks', () async {
        final img = await _tempImageFile();
        final requestBodies = await _captureClaudeToolLoop(
          stream: true,
          sendRequest: (baseUrl) {
            return ChatApiService.sendMessageStream(
              config: _claudeConfig(baseUrl),
              modelId: 'claude-sonnet-5',
              messages: const [
                {'role': 'user', 'content': 'inspect'},
              ],
              tools: const [_lookupTool],
              onToolCall: (_, __, {toolCallId}) async =>
                  'result [image:${img['path']}]',
            ).toList();
          },
        );

        expect(requestBodies, hasLength(2));
        final toolResult = _claudeToolResultOf(requestBodies[1]);
        expect(toolResult['content'], isA<List>());
        final blocks = toolResult['content'] as List;
        expect(blocks, hasLength(2));
        expect(blocks.first, {'type': 'text', 'text': 'result'});
        expect(blocks.last['source'], {
          'type': 'base64',
          'media_type': 'image/png',
          'data': 'AQIDBA==',
        });
      });

      test('remote URL image becomes an url-source image block', () async {
        final body = await _captureClaudeBody((baseUrl) {
          return ChatApiService.sendMessageStream(
            config: _claudeConfig(baseUrl),
            modelId: 'claude-sonnet-5',
            messages: const [
              {
                'role': 'tool',
                'tool_call_id': 'toolu_1',
                'content': 'result [image:https://example.com/photo.png]',
              },
            ],
            stream: false,
          ).toList();
        });

        final toolResult = _claudeToolResultOf(body);
        final blocks = toolResult['content'] as List;
        expect(blocks, hasLength(2));
        expect(blocks.last['type'], 'image');
        expect(blocks.last['source'], {
          'type': 'url',
          'url': 'https://example.com/photo.png',
        });
      });
    });

    group('LongCat Omni', () {
      test('live loop: tool result becomes input_image parts', () async {
        final img = await _tempImageFile();
        final requestBodies = await _captureChatToolLoop((baseUrl) {
          return ChatApiService.sendMessageStream(
            config: _openAiConfig(baseUrl),
            modelId: 'longcat-flash-omni',
            messages: const [
              {'role': 'user', 'content': 'inspect'},
            ],
            tools: const [_lookupTool],
            onToolCall: (_, __, {toolCallId}) async =>
                'result\n[image:${img['path']}]',
            stream: false,
          ).toList();
        });

        expect(requestBodies, hasLength(2));
        final toolMessage = _toolMessageOf(requestBodies[1]);
        final content = toolMessage['content'] as List;
        expect(content, hasLength(2));
        expect(content.first, {'type': 'text', 'text': 'result'});
        expect(content.last['type'], 'input_image');
        expect(content.last['input_image'], {
          'type': 'base64',
          'data': ['AQIDBA=='],
        });
      });
    });
  });
}

const Map<String, dynamic> _lookupTool = {
  'type': 'function',
  'function': {
    'name': 'lookup',
    'description': 'Lookup test data',
    'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
  },
};

Map<String, dynamic> _toolMessageOf(Map<String, dynamic> body) {
  final messages = (body['messages'] as List)
      .map((e) => (e as Map).cast<String, dynamic>())
      .toList(growable: false);
  return messages.firstWhere((m) => m['role'] == 'tool');
}

Map<String, dynamic> _functionCallOutputOf(Map<String, dynamic> body) {
  final input = (body['input'] as List)
      .map((e) => (e as Map).cast<String, dynamic>())
      .toList(growable: false);
  return input.firstWhere((item) => item['type'] == 'function_call_output');
}

Map<String, dynamic> _claudeToolResultOf(Map<String, dynamic> body) {
  final messages = (body['messages'] as List)
      .map((e) => (e as Map).cast<String, dynamic>())
      .toList(growable: false);
  for (final m in messages) {
    final content = m['content'];
    if (content is! List) continue;
    for (final block in content) {
      if (block is Map && (block['type'] == 'tool_result')) {
        return block.cast<String, dynamic>();
      }
    }
  }
  fail('no tool_result block found in Claude request body');
}

Future<Map<String, dynamic>> _captureChatBody(
  Future<List<dynamic>> Function(String baseUrl) sendRequest,
) async {
  Map<String, dynamic>? requestBody;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final baseUrl = 'http://${server.address.address}:${server.port}/v1';
  try {
    server.listen((request) async {
      final rawBody = await utf8.decoder.bind(request).join();
      requestBody = (jsonDecode(rawBody) as Map).cast<String, dynamic>();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'id': 'chatcmpl-1',
          'object': 'chat.completion',
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
          'usage': {
            'prompt_tokens': 1,
            'completion_tokens': 1,
            'total_tokens': 2,
          },
        }),
      );
      await request.response.close();
    });
    final chunks = await sendRequest(baseUrl);
    expect(chunks, isNotEmpty);
    expect(requestBody, isNotNull);
    return requestBody!;
  } finally {
    await server.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> _captureChatToolLoop(
  Future<List<dynamic>> Function(String baseUrl) sendRequest,
) async {
  final requestBodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final baseUrl = 'http://${server.address.address}:${server.port}/v1';
  var requestCount = 0;
  try {
    server.listen((request) async {
      requestCount += 1;
      final rawBody = await utf8.decoder.bind(request).join();
      requestBodies.add((jsonDecode(rawBody) as Map).cast<String, dynamic>());
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      final String payload;
      if (requestCount == 1) {
        payload = jsonEncode({
          'id': 'chatcmpl-tool-1',
          'object': 'chat.completion',
          'choices': [
            {
              'index': 0,
              'message': {
                'role': 'assistant',
                'content': 'checking',
                'tool_calls': [
                  {
                    'id': 'call_1',
                    'type': 'function',
                    'function': {'name': 'lookup', 'arguments': '{}'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        });
      } else {
        payload = jsonEncode({
          'id': 'chatcmpl-tool-2',
          'object': 'chat.completion',
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': 'done'},
              'finish_reason': 'stop',
            },
          ],
          'usage': {
            'prompt_tokens': 1,
            'completion_tokens': 1,
            'total_tokens': 2,
          },
        });
      }
      request.response.write(payload);
      await request.response.close();
    });
    final chunks = await sendRequest(baseUrl);
    expect(chunks, isNotEmpty);
    return requestBodies;
  } finally {
    await server.close(force: true);
  }
}

Future<Map<String, dynamic>> _captureResponsesBody(
  Future<List<dynamic>> Function(String baseUrl) sendRequest,
) async {
  Map<String, dynamic>? requestBody;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final baseUrl = 'http://${server.address.address}:${server.port}/v1';
  try {
    server.listen((request) async {
      final rawBody = await utf8.decoder.bind(request).join();
      requestBody = (jsonDecode(rawBody) as Map).cast<String, dynamic>();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: ${jsonEncode({
          'type': 'response.completed',
          'response': {
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'ok'},
                ],
              },
            ],
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          },
        })}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    final chunks = await sendRequest(baseUrl);
    expect(chunks, isNotEmpty);
    expect(requestBody, isNotNull);
    return requestBody!;
  } finally {
    await server.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> _captureResponsesToolLoop(
  Future<List<dynamic>> Function(String baseUrl) sendRequest,
) async {
  final requestBodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final baseUrl = 'http://${server.address.address}:${server.port}/v1';
  var requestCount = 0;
  try {
    server.listen((request) async {
      requestCount += 1;
      final rawBody = await utf8.decoder.bind(request).join();
      requestBodies.add((jsonDecode(rawBody) as Map).cast<String, dynamic>());
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      if (requestCount == 1) {
        request.response.write(
          'data: ${jsonEncode({
            'type': 'response.output_item.done',
            'output_index': 0,
            'item': {'type': 'function_call', 'call_id': 'call_1', 'name': 'lookup', 'arguments': '{}'},
          })}\n\n',
        );
        request.response.write(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'output': [
                {'type': 'function_call', 'call_id': 'call_1', 'name': 'lookup', 'arguments': '{}'},
              ],
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            },
          })}\n\n',
        );
      } else {
        request.response.write(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'output': [
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': 'done'},
                  ],
                },
              ],
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            },
          })}\n\n',
        );
      }
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    final chunks = await sendRequest(baseUrl);
    expect(chunks, isNotEmpty);
    return requestBodies;
  } finally {
    await server.close(force: true);
  }
}

Future<Map<String, dynamic>> _captureClaudeBody(
  Future<List<dynamic>> Function(String baseUrl) sendRequest,
) async {
  Map<String, dynamic>? requestBody;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final baseUrl = 'http://${server.address.address}:${server.port}';
  try {
    server.listen((request) async {
      final rawBody = await utf8.decoder.bind(request).join();
      requestBody = (jsonDecode(rawBody) as Map).cast<String, dynamic>();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'id': 'msg_1',
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
          'model': 'claude-sonnet-5',
          'stop_reason': 'end_turn',
          'usage': {'input_tokens': 1, 'output_tokens': 1},
        }),
      );
      await request.response.close();
    });
    final chunks = await sendRequest(baseUrl);
    expect(chunks, isNotEmpty);
    expect(requestBody, isNotNull);
    return requestBody!;
  } finally {
    await server.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> _captureClaudeToolLoop({
  required bool stream,
  required Future<List<dynamic>> Function(String baseUrl) sendRequest,
}) async {
  final requestBodies = <Map<String, dynamic>>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final baseUrl = 'http://${server.address.address}:${server.port}';
  var requestCount = 0;
  try {
    server.listen((request) async {
      requestCount += 1;
      final rawBody = await utf8.decoder.bind(request).join();
      requestBodies.add((jsonDecode(rawBody) as Map).cast<String, dynamic>());
      request.response.statusCode = HttpStatus.ok;
      if (stream) {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        if (requestCount == 1) {
          request.response.write('''
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","stop_reason":null}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"lookup","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":1,"output_tokens":1}}

event: message_stop
data: {"type":"message_stop"}

''');
        } else {
          request.response.write('''
event: message_start
data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","stop_reason":null}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":1,"output_tokens":1}}

event: message_stop
data: {"type":"message_stop"}

''');
        }
      } else {
        request.response.headers.contentType = ContentType.json;
        final String payload;
        if (requestCount == 1) {
          payload = jsonEncode({
            'id': 'msg_1',
            'type': 'message',
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'lookup',
                'input': <String, dynamic>{},
              },
            ],
            'model': 'claude-sonnet-5',
            'stop_reason': 'tool_use',
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          });
        } else {
          payload = jsonEncode({
            'id': 'msg_2',
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'done'},
            ],
            'model': 'claude-sonnet-5',
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 1, 'output_tokens': 1},
          });
        }
        request.response.write(payload);
      }
      await request.response.close();
    });
    final chunks = await sendRequest(baseUrl);
    expect(chunks, isNotEmpty);
    return requestBodies;
  } finally {
    await server.close(force: true);
  }
}
