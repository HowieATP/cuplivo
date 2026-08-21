import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/core/services/api/chat_api_service.dart';

ProviderConfig _geminiConfig(String baseUrl) {
  return ProviderConfig(
    id: 'GeminiToolSchemaStripTest',
    enabled: true,
    name: 'GeminiToolSchemaStripTest',
    apiKey: 'test-key',
    baseUrl: baseUrl,
    providerType: ProviderKind.google,
  );
}

Future<HttpServer> _startGeminiServer(
  void Function(Map<String, dynamic> body) onBody,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final bodyText = await utf8.decoder.bind(request).join();
    onBody(jsonDecode(bodyText) as Map<String, dynamic>);

    request.response.statusCode = HttpStatus.ok;
    if (request.uri.path.endsWith(':streamGenerateContent')) {
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: ${jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'ok'},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
          'usageMetadata': {'promptTokenCount': 1, 'candidatesTokenCount': 1, 'totalTokenCount': 2},
        })}\n\n',
      );
      request.response.write('data: [DONE]');
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'ok'},
                ],
              },
            },
          ],
          'usageMetadata': {
            'promptTokenCount': 1,
            'candidatesTokenCount': 1,
            'totalTokenCount': 2,
          },
        }),
      );
    }
    await request.response.close();
  });
  return server;
}

void _expectNoAdditionalProperties(dynamic node) {
  if (node is Map) {
    expect(
      node.containsKey('additionalProperties'),
      isFalse,
      reason: 'Gemini rejects additionalProperties (issue #425): $node',
    );
    for (final v in node.values) {
      _expectNoAdditionalProperties(v);
    }
  } else if (node is List) {
    for (final v in node) {
      _expectNoAdditionalProperties(v);
    }
  }
}

List<Map<String, dynamic>> _toolWithAdditionalProperties() {
  return [
    {
      'type': 'function',
      'function': {
        'name': 'fetch_page',
        'description': 'Fetch a page',
        'parameters': {
          'type': 'object',
          'additionalProperties': true,
          'properties': {
            'url': {'type': 'string'},
            'headers': {
              'type': 'object',
              'additionalProperties': {'type': 'string'},
            },
            'nested': {
              'type': 'object',
              'properties': {
                'config': {'type': 'object', 'additionalProperties': true},
              },
            },
            'rows': {
              'type': 'array',
              'items': {
                'type': 'object',
                'additionalProperties': {'type': 'string'},
              },
            },
            'choice': {
              'anyOf': [
                {'type': 'string'},
                {
                  'type': 'object',
                  'additionalProperties': {'type': 'number'},
                },
              ],
            },
            'tuple': {
              'type': 'array',
              'items': [
                {'type': 'string'},
                {
                  'type': 'object',
                  'additionalProperties': {'type': 'boolean'},
                },
              ],
            },
          },
          'required': ['url'],
        },
      },
    },
  ];
}

void _verifyStripped(Map<String, dynamic> capturedBody) {
  final tools = capturedBody['tools'] as List;
  expect(tools, hasLength(1));
  final decls = (tools.first as Map)['function_declarations'] as List;
  expect(decls, hasLength(1));
  final parameters = ((decls.first as Map)['parameters'] as Map)
      .cast<String, dynamic>();
  expect(parameters['type'], 'object');
  _expectNoAdditionalProperties(parameters);

  // Stripping must not reshape object schemas: array-item / property objects
  // stay bare {type: object}, matching the sanitized MCP path.
  final props = parameters['properties'] as Map<String, dynamic>;
  expect(props['headers'], {'type': 'object'});
  expect(props['rows'], {
    'type': 'array',
    'items': {'type': 'object'},
  });
  expect(props['choice'], {
    'anyOf': [
      {'type': 'string'},
      {'type': 'object'},
    ],
  });
  expect(props['tuple'], {
    'type': 'array',
    'items': [
      {'type': 'string'},
      {'type': 'object'},
    ],
  });
}

void main() {
  group('Gemini tool schema stripping', () {
    for (final stream in const [false, true]) {
      test('strips additionalProperties in ${stream ? 'stream' : 'non-stream'} '
          'requests', () async {
        late Map<String, dynamic> capturedBody;
        final server = await _startGeminiServer((body) {
          capturedBody = body;
        });
        addTearDown(() async {
          await server.close(force: true);
        });

        final chunks = await ChatApiService.sendMessageStream(
          config: _geminiConfig(
            'http://${server.address.address}:${server.port}/v1beta',
          ),
          modelId: 'google/gemini-3.5-flash-lite',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          tools: _toolWithAdditionalProperties(),
          stream: stream,
        ).toList();

        expect(chunks.last.isDone, isTrue);
        _verifyStripped(capturedBody);
      });
    }
  });
}
