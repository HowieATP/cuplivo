import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

ProviderConfig _googleConfig(String baseUrl) {
  return ProviderConfig(
    id: 'GoogleParallelToolTest',
    enabled: true,
    name: 'GoogleParallelToolTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.google,
  );
}

ProviderConfig _claudeConfig(String baseUrl) {
  return ProviderConfig(
    id: 'ClaudeParallelToolTest',
    enabled: true,
    name: 'ClaudeParallelToolTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.claude,
  );
}

Map<String, dynamic> _googleStreamChunk(
  List<Map<String, dynamic>> parts, {
  String? finishReason,
}) {
  return {
    'candidates': [
      {
        'content': {'parts': parts},
        if (finishReason != null) 'finishReason': finishReason,
      },
    ],
  };
}

Map<String, dynamic> _googleFunctionCall(
  String name,
  Map<String, dynamic> args, {
  String? id,
}) {
  return {
    'functionCall': {if (id != null) 'id': id, 'name': name, 'args': args},
  };
}

Future<void> _writeSseResponse(
  HttpResponse response,
  Iterable<Map<String, dynamic>> chunks,
) async {
  response.statusCode = HttpStatus.ok;
  response.headers.contentType = ContentType('text', 'event-stream');
  response.headers.set('Transfer-Encoding', 'chunked');
  for (final chunk in chunks) {
    response.write('data: ${jsonEncode(chunk)}\n\n');
  }
  response.write('data: [DONE]\n\n');
  await response.close();
}

Future<Map<String, dynamic>> _jsonRequestBody(HttpRequest request) async {
  return (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
      .cast<String, dynamic>();
}

void main() {
  group('parallel tool call protocol', () {
    test(
      'groups parallel historical Google tool results into one user turn',
      () async {
        late Map<String, dynamic> requestBody;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((request) async {
          requestBody = await _jsonRequestBody(request);
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'done'},
                    ],
                  },
                  'finishReason': 'STOP',
                },
              ],
            }),
          );
          await request.response.close();
        });

        await ChatApiService.sendMessageStream(
          config: _googleConfig(
            'http://${server.address.address}:${server.port}/v1beta',
          ),
          modelId: 'gemini-2.5-pro',
          messages: const [
            {'role': 'user', 'content': '查两个信息'},
            {
              'role': 'assistant',
              'content': '\n\n',
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'lookup_city',
                    'arguments': '{"city":"Hangzhou"}',
                  },
                },
                {
                  'id': 'call_2',
                  'type': 'function',
                  'function': {
                    'name': 'lookup_time',
                    'arguments': '{"city":"Hangzhou"}',
                  },
                },
              ],
            },
            {
              'role': 'tool',
              'tool_call_id': 'call_1',
              'name': 'lookup_city',
              'content': '{"temperature":20}',
            },
            {
              'role': 'tool',
              'tool_call_id': 'call_2',
              'name': 'lookup_time',
              'content': '{"time":"15:00"}',
            },
            {'role': 'user', 'content': '继续总结'},
          ],
          stream: false,
        ).toList();

        final contents = (requestBody['contents'] as List).cast<Map>();
        expect(contents.map((content) => content['role']).toList(), [
          'user',
          'model',
          'user',
          'user',
        ]);
        final responseParts = (contents[2]['parts'] as List).cast<Map>();
        expect(
          responseParts
              .map((part) => part['functionResponse']['name'])
              .toList(),
          ['lookup_city', 'lookup_time'],
        );
      },
    );

    test(
      'returns parallel Google streaming calls in one follow-up turn',
      () async {
        final requestBodies = <Map<String, dynamic>>[];
        var requestCount = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((request) async {
          requestCount++;
          requestBodies.add(await _jsonRequestBody(request));
          if (requestCount == 1) {
            await _writeSseResponse(request.response, [
              _googleStreamChunk([
                _googleFunctionCall('lookup_city', {
                  'city': 'Hangzhou',
                }, id: 'api_city_call'),
                _googleFunctionCall('lookup_time', {
                  'city': 'Hangzhou',
                }, id: 'api_time_call'),
              ], finishReason: 'STOP'),
            ]);
            return;
          }
          await _writeSseResponse(request.response, [
            _googleStreamChunk([
              {'text': 'done'},
            ], finishReason: 'STOP'),
          ]);
        });

        final seenToolCallIds = <String?>[];
        final chunks = await ChatApiService.sendMessageStream(
          config: _googleConfig(
            'http://${server.address.address}:${server.port}/v1beta',
          ),
          modelId: 'gemini-2.5-pro',
          messages: const [
            {'role': 'user', 'content': '查两个信息'},
          ],
          tools: const [
            {
              'type': 'function',
              'function': {
                'name': 'lookup_city',
                'parameters': {'type': 'object'},
              },
            },
            {
              'type': 'function',
              'function': {
                'name': 'lookup_time',
                'parameters': {'type': 'object'},
              },
            },
          ],
          onToolCall: (name, args, {toolCallId}) async {
            seenToolCallIds.add(toolCallId);
            return name == 'lookup_city'
                ? 'not-json-tool-result'
                : jsonEncode({'tool': name});
          },
        ).toList();

        expect(chunks.last.isDone, isTrue);
        expect(requestBodies, hasLength(2));
        final followUpContents = (requestBodies[1]['contents'] as List)
            .cast<Map>();
        expect(followUpContents.map((content) => content['role']).toList(), [
          'user',
          'model',
          'user',
        ]);
        expect(
          (followUpContents[1]['parts'] as List)
              .where((part) => (part as Map).containsKey('functionCall'))
              .length,
          2,
        );
        expect(seenToolCallIds, ['api_city_call', 'api_time_call']);
        expect(
          (followUpContents[1]['parts'] as List)
              .map((part) => (part as Map)['functionCall']['id'])
              .toList(),
          ['api_city_call', 'api_time_call'],
        );
        expect(
          (followUpContents[2]['parts'] as List)
              .map((part) => (part as Map)['functionResponse']['name'])
              .toList(),
          ['lookup_city', 'lookup_time'],
        );
        expect(
          (followUpContents[2]['parts'] as List)
              .map((part) => (part as Map)['functionResponse']['id'])
              .toList(),
          ['api_city_call', 'api_time_call'],
        );
        expect(
          (followUpContents[2]['parts'] as List)
              .first['functionResponse']['response'],
          {'result': 'not-json-tool-result'},
        );
      },
    );

    test(
      'returns all parallel Anthropic streaming tool results together',
      () async {
        final requestBodies = <Map<String, dynamic>>[];
        var requestCount = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((request) async {
          requestCount++;
          requestBodies.add(await _jsonRequestBody(request));
          if (requestCount == 1) {
            await _writeSseResponse(request.response, [
              {
                'type': 'message_start',
                'message': {'id': 'msg_1'},
              },
              {
                'type': 'content_block_start',
                'index': 0,
                'content_block': {
                  'type': 'tool_use',
                  'id': 'toolu_1',
                  'name': 'lookup_city',
                  'input': {},
                },
              },
              {
                'type': 'content_block_delta',
                'index': 0,
                'delta': {
                  'type': 'input_json_delta',
                  'partial_json': '{"city":"Hangzhou"}',
                },
              },
              {
                'type': 'content_block_stop',
                'index': 0,
                'content_block': {'id': 'toolu_1'},
              },
              {
                'type': 'content_block_start',
                'index': 1,
                'content_block': {
                  'type': 'tool_use',
                  'id': 'toolu_2',
                  'name': 'lookup_time',
                  'input': {},
                },
              },
              {
                'type': 'content_block_delta',
                'index': 1,
                'delta': {
                  'type': 'input_json_delta',
                  'partial_json': '{"city":"Hangzhou"}',
                },
              },
              {
                'type': 'content_block_stop',
                'index': 1,
                'content_block': {'id': 'toolu_2'},
              },
              {
                'type': 'message_delta',
                'delta': {'stop_reason': 'tool_use'},
              },
              {'type': 'message_stop'},
            ]);
            return;
          }
          await _writeSseResponse(request.response, [
            {
              'type': 'message_start',
              'message': {'id': 'msg_2'},
            },
            {
              'type': 'content_block_start',
              'index': 0,
              'content_block': {'type': 'text', 'text': ''},
            },
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'text_delta', 'text': 'done'},
            },
            {'type': 'content_block_stop', 'index': 0},
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'end_turn'},
            },
            {'type': 'message_stop'},
          ]);
        });

        final chunks = await ChatApiService.sendMessageStream(
          config: _claudeConfig(
            'http://${server.address.address}:${server.port}',
          ),
          modelId: 'claude-sonnet-4-6',
          messages: const [
            {'role': 'user', 'content': '查两个信息'},
          ],
          tools: const [
            {
              'type': 'function',
              'function': {
                'name': 'lookup_city',
                'parameters': {'type': 'object'},
              },
            },
            {
              'type': 'function',
              'function': {
                'name': 'lookup_time',
                'parameters': {'type': 'object'},
              },
            },
          ],
          onToolCall: (name, args, {toolCallId}) async =>
              jsonEncode({'tool': name}),
        ).toList();

        expect(chunks.last.isDone, isTrue);
        final followUpMessages = (requestBodies[1]['messages'] as List)
            .cast<Map>();
        expect(followUpMessages.map((message) => message['role']).toList(), [
          'user',
          'assistant',
          'user',
        ]);
        expect(
          (followUpMessages[1]['content'] as List)
              .where((block) => (block as Map)['type'] == 'tool_use')
              .length,
          2,
        );
        expect(
          (followUpMessages[2]['content'] as List)
              .map((block) => (block as Map)['tool_use_id'])
              .toList(),
          ['toolu_1', 'toolu_2'],
        );
      },
    );
  });
}
