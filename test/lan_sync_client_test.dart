import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/database/chat_database_repository.dart';
import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/models/chat_message.dart';
import 'package:Cuplivo/core/models/conversation.dart';
import 'package:Cuplivo/core/services/backup/data_sync.dart';
import 'package:Cuplivo/core/services/chat/chat_service.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_client.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_logic.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_models.dart';
import 'package:Cuplivo/core/services/sync/lan_sync_server.dart';
import 'package:Cuplivo/core/services/sync/windows_firewall.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

/// Minimal ChatService fake: only the index-building surface is real,
/// backed by an in-memory Drift repo.
class _FakeChatService extends ChatService {
  _FakeChatService(this._repo);

  final ChatDatabaseRepository _repo;
  final List<Conversation> _conversations = [];

  @override
  ChatDatabaseRepository get repo => _repo;

  /// Export paths (`_exportChatsToFile`, `_exportSettingsJson`) self-init
  /// when uninitialized — that would open a real SQLite file under the fake
  /// app-data dir and leave it locked for the teardown delete.
  @override
  bool get initialized => true;

  @override
  List<Conversation> getAllCompleteConversations() => _conversations;

  @override
  Future<List<Assistant>> getAllAssistants() => _repo.getAllAssistants();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('lanSyncFindProxy', () {
    test('always returns DIRECT regardless of scheme or host', () {
      expect(
        lanSyncFindProxy(Uri.parse('http://192.168.1.100:9527/sync/plan')),
        'DIRECT',
      );
      expect(lanSyncFindProxy(Uri.parse('https://example.com')), 'DIRECT');
    });
  });

  group('filterLanIps', () {
    test('keeps non-loopback, drops loopback, dedupes, preserves order', () {
      expect(
        filterLanIps(['192.168.1.5', '127.0.0.1', '192.168.1.5', '10.0.0.2']),
        ['192.168.1.5', '10.0.0.2'],
      );
    });

    test('returns empty for all-loopback input', () {
      expect(filterLanIps(['127.0.0.1', '127.0.0.2']), isEmpty);
    });

    test('returns empty for empty input', () {
      expect(filterLanIps([]), isEmpty);
    });
  });

  group('WindowsFirewall helpers', () {
    test('rule name embeds the port without spaces or parentheses', () {
      expect(WindowsFirewall.ruleName(9527), 'Cuplivo-LanSync-TCP-9527');
      expect(WindowsFirewall.ruleName(12345), 'Cuplivo-LanSync-TCP-12345');
    });

    test('add-rule args are port-scoped', () {
      expect(WindowsFirewall.addRuleArgs(9527), [
        'advfirewall',
        'firewall',
        'add',
        'rule',
        'name=Cuplivo-LanSync-TCP-9527',
        'dir=in',
        'action=allow',
        'protocol=TCP',
        'localport=9527',
      ]);
    });

    test('show-rule args reference the same name', () {
      expect(WindowsFirewall.showRuleArgs(9527), [
        'advfirewall',
        'firewall',
        'show',
        'rule',
        'name=Cuplivo-LanSync-TCP-9527',
      ]);
    });

    test('delete-rule args reference the same name', () {
      expect(WindowsFirewall.deleteRuleArgs(9527), [
        'advfirewall',
        'firewall',
        'delete',
        'rule',
        'name=Cuplivo-LanSync-TCP-9527',
      ]);
    });

    test('elevated command re-invokes netsh via Start-Process -Verb RunAs', () {
      final cmd = WindowsFirewall.elevateAddRuleCommand(9527);
      expect(cmd, contains('Start-Process -Verb RunAs'));
      expect(cmd, contains("'name=Cuplivo-LanSync-TCP-9527'"));
      expect(cmd, contains("'localport=9527'"));
    });
  });

  group('LanSyncClient', () {
    late Directory tempDir;
    late ChatDatabaseRepository repo;
    late _FakeChatService chatService;
    late DataSync dataSync;

    /// Plan with a null `since` — exchange then never touches DataSync.
    late SyncPlan emptyPlan;

    setUp(() async {
      // getMessageIdsSync reads a separate raw-sqlite sync connection, which
      // only exists for file-based repos after ensureReady().
      tempDir = await Directory.systemTemp.createTemp('cuplivo_lan_sync_test');
      final dbFile = File('${tempDir.path}${Platform.pathSeparator}test.db');
      repo = ChatDatabaseRepository.open(file: dbFile);
      await repo.ensureReady();
      chatService = _FakeChatService(repo);
      dataSync = DataSync(chatService: chatService);
      emptyPlan = SyncPlan(
        conversations: const [],
        missingAssistantIds: const [],
        remoteMissingAssistantIds: const [],
        since: null,
      );
    });

    tearDown(() async {
      await repo.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    http.Client clientWith({
      required http.Response Function() planResponse,
      required http.Response Function() exchangeResponse,
    }) {
      return MockClient((request) async {
        if (request.url.path == '/sync/plan') return planResponse();
        if (request.url.path == '/sync/exchange') return exchangeResponse();
        return http.Response('Not found', 404);
      });
    }

    test('negotiate sends index with PIN header and parses the plan', () async {
      final assistant = Assistant(id: 'a1', name: 'Alpha');
      await repo.putAssistants([assistant]);
      final conversation = Conversation(id: 'c1', title: 'Chat 1');
      await repo.putConversation(conversation);
      await repo.putMessage(
        ChatMessage(
          id: 'm1',
          role: 'user',
          content: 'hello',
          conversationId: 'c1',
          timestamp: DateTime(2025, 1, 1),
        ),
      );
      chatService._conversations.add(conversation);

      late http.Request captured;
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(emptyPlan.toJsonString(), 200);
        }),
      );

      final plan = await lanClient.negotiate(
        host: '192.168.1.100',
        port: 9527,
        pin: '1234',
      );

      expect(captured.url.toString(), 'http://192.168.1.100:9527/sync/plan');
      expect(captured.headers['X-Sync-Pin'], '1234');
      expect(captured.headers['Content-Type'], startsWith('application/json'));
      final sent = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(sent['conversations'], contains('c1'));
      expect(sent['conversations']['c1'], contains('m1'));
      expect(sent['assistantIds'], contains('a1'));
      expect(plan, same(lanClient.plan));
      expect(lanClient.phase, LanSyncPhase.planReceived);
    });

    test('negotiate throws on 401 (invalid PIN)', () async {
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response('Invalid PIN', 401),
          exchangeResponse: () => http.Response('unused', 500),
        ),
      );
      await expectLater(
        lanClient.negotiate(host: '192.168.1.100', port: 9527, pin: '0000'),
        throwsA(predicate((e) => '$e'.contains('Invalid PIN'))),
      );
      expect(lanClient.busy, isFalse);
    });

    test('negotiate throws on non-200 response', () async {
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response('boom', 500),
          exchangeResponse: () => http.Response('unused', 500),
        ),
      );
      await expectLater(
        lanClient.negotiate(host: '192.168.1.100', port: 9527, pin: '1234'),
        throwsA(predicate((e) => '$e'.contains('Plan request failed'))),
      );
    });

    test('exchange on failure resets phase and stays retryable', () async {
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response(emptyPlan.toJsonString(), 200),
          exchangeResponse: () => http.Response('boom', 500),
        ),
      );
      await lanClient.negotiate(host: '192.168.1.100', port: 9527, pin: '1234');
      await expectLater(
        lanClient.exchange(host: '192.168.1.100', port: 9527, pin: '1234'),
        throwsA(predicate((e) => '$e'.contains('Exchange failed'))),
      );
      expect(lanClient.phase, LanSyncPhase.planReceived);
      expect(lanClient.busy, isFalse);
    });

    test(
      'exchange keeps phase done when the restore callback throws',
      () async {
        // The restore flow pops the sheet itself (widget layer). When the
        // restore callback throws, the phase must stay `done` (NOT reset to
        // planReceived) so the widget's `_exchange` returns false and the
        // caller does not pop a second time (issue #182 double-pop guard).
        final zipBytes = utf8.encode('PK fake zip content');
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: clientWith(
            planResponse: () => http.Response(emptyPlan.toJsonString(), 200),
            exchangeResponse: () => http.Response.bytes(
              zipBytes,
              200,
              headers: {'content-type': 'application/zip'},
            ),
          ),
        );
        lanClient.onZipReceived = (zipFile) async {
          throw Exception('restore failed');
        };

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );
        await expectLater(
          lanClient.exchange(host: '192.168.1.100', port: 9527, pin: '1234'),
          throwsA(predicate((e) => '$e'.contains('restore failed'))),
        );
        expect(lanClient.phase, LanSyncPhase.done);
        expect(lanClient.busy, isFalse);
      },
    );

    test(
      'exchange with empty response enters noData and skips restore',
      () async {
        var zipCallbackCalled = false;
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: clientWith(
            planResponse: () => http.Response(emptyPlan.toJsonString(), 200),
            exchangeResponse: () => http.Response(
              '{"empty":true}',
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        lanClient.onZipReceived = (zipFile) async {
          zipCallbackCalled = true;
        };

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );
        await lanClient.exchange(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );

        expect(lanClient.phase, LanSyncPhase.noData);
        expect(zipCallbackCalled, isFalse);
      },
    );

    test('exchange with zip response saves the file and enters done', () async {
      final zipBytes = utf8.encode('PK fake zip content');
      File? receivedFile;
      final lanClient = LanSyncClient(
        chatService: chatService,
        dataSync: dataSync,
        httpClient: clientWith(
          planResponse: () => http.Response(emptyPlan.toJsonString(), 200),
          exchangeResponse: () => http.Response.bytes(
            zipBytes,
            200,
            headers: {'content-type': 'application/zip'},
          ),
        ),
      );
      lanClient.onZipReceived = (zipFile) async {
        receivedFile = zipFile;
      };

      await lanClient.negotiate(host: '192.168.1.100', port: 9527, pin: '1234');
      await lanClient.exchange(host: '192.168.1.100', port: 9527, pin: '1234');

      expect(lanClient.phase, LanSyncPhase.done);
      expect(receivedFile, isNotNull);
      expect(await receivedFile!.exists(), isTrue);
      expect(await receivedFile!.readAsBytes(), zipBytes);
      await receivedFile!.delete();
    });

    test(
      'exchange zip includes settings.json so settings/assistants sync',
      () async {
        // Full DataSync export path needs prefs + path provider fakes.
        SharedPreferences.setMockInitialValues({});
        PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);

        final conversation = Conversation(id: 'c1', title: 'Chat 1');
        await repo.putConversation(conversation);
        await repo.putMessage(
          ChatMessage(
            id: 'm1',
            role: 'user',
            content: 'hello',
            conversationId: 'c1',
            timestamp: DateTime(2025, 1, 1),
          ),
        );
        chatService._conversations.add(conversation);

        final plan = SyncPlan(
          conversations: const [],
          missingAssistantIds: const [],
          remoteMissingAssistantIds: const [],
          since: DateTime(2025, 1, 1),
        );
        late http.Request captured;
        final lanClient = LanSyncClient(
          chatService: chatService,
          dataSync: dataSync,
          httpClient: MockClient((request) async {
            if (request.url.path == '/sync/plan') {
              return http.Response(plan.toJsonString(), 200);
            }
            captured = request;
            return http.Response(
              '{"empty":true}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        await lanClient.negotiate(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );
        await lanClient.exchange(
          host: '192.168.1.100',
          port: 9527,
          pin: '1234',
        );

        expect(lanClient.phase, LanSyncPhase.noData);
        expect(captured, isNotNull);
        final contentType = captured.headers['content-type']!;
        expect(contentType, startsWith('multipart/form-data'));
        final boundary = contentType.split('boundary=').last;
        final parts = parseMultipartBytes(captured.bodyBytes, boundary);
        final zipBytes = parts['zip'];
        expect(zipBytes, isNotNull);

        final archive = ZipDecoder().decodeBytes(zipBytes!);
        try {
          expect(archive.findFile('settings.json'), isNotNull);
          expect(archive.findFile('chats.json'), isNotNull);
        } finally {
          archive.clearSync();
        }
      },
    );
  });
}
