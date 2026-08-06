import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:Cuplivo/core/providers/mcp_provider.dart';

McpServerConfig _server(String id, String name) => McpServerConfig(
  id: id,
  name: name,
  enabled: false,
  transport: McpTransportType.http,
  url: 'http://127.0.0.1:1/$id',
);

Future<Set<String>> _persistedServerIds() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('mcp_servers_v1');
  if (raw == null || raw.isEmpty) return <String>{};
  final list = jsonDecode(raw) as List;
  return list
      .map((e) => ((e as Map)['id'] ?? '').toString())
      .where((id) => id.isNotEmpty)
      .toSet();
}

void main() {
  test(
    'reloadFromPrefs rebuilds the server list and timeout from SharedPreferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'mcp_servers_v1': jsonEncode([_server('srv-a', 'Server A').toJson()]),
        'mcp_request_timeout_ms_v1': 15000,
      });

      final provider = McpProvider(
        contextProvider: () => throw UnimplementedError(),
      );
      await pumpEventQueue();

      expect(provider.servers.map((s) => s.id), contains('srv-a'));
      expect(provider.requestTimeoutSeconds, 15);

      // Simulate a restore that rewrote the prefs (e.g. overwrite restore of
      // mcp_servers_v1). The in-memory list must follow disk, not keep the
      // pre-restore servers.
      SharedPreferences.setMockInitialValues({
        'mcp_servers_v1': jsonEncode([_server('srv-b', 'Server B').toJson()]),
        'mcp_request_timeout_ms_v1': 42000,
      });
      await provider.reloadFromPrefs();

      final ids = provider.servers.map((s) => s.id).toList();
      expect(ids, contains('srv-b'));
      expect(ids, isNot(contains('srv-a')));
      expect(provider.requestTimeoutSeconds, 42);

      // Stop the built-in servers' auto-connect (heartbeat timers) so the
      // test ends without pending timers.
      for (final s in provider.servers) {
        await provider.disconnect(s.id);
      }
    },
  );

  test(
    'refreshTools after disconnect never writes stale servers back to prefs',
    () async {
      // Start with the pre-restore list.
      SharedPreferences.setMockInitialValues({
        'mcp_servers_v1': jsonEncode([_server('srv-a', 'Server A').toJson()]),
      });
      final provider = McpProvider(
        contextProvider: () => throw UnimplementedError(),
      );
      await pumpEventQueue();
      expect(provider.servers.map((s) => s.id), contains('srv-a'));

      // Restore rewrote prefs to the new list; the old client is disconnected
      // before the in-memory state is rebuilt. A tool refresh fired from the
      // old client (assistant-change listener) must not persist the old list.
      SharedPreferences.setMockInitialValues({
        'mcp_servers_v1': jsonEncode([_server('srv-b', 'Server B').toJson()]),
      });
      await provider.disconnect('kelivo_subagent');
      await provider.refreshTools('kelivo_subagent');

      expect(await _persistedServerIds(), contains('srv-b'));
      expect(await _persistedServerIds(), isNot(contains('srv-a')));

      for (final s in provider.servers) {
        await provider.disconnect(s.id);
      }
    },
  );

  test('refreshTools after reload keeps the restored list in prefs', () async {
    SharedPreferences.setMockInitialValues({
      'mcp_servers_v1': jsonEncode([_server('srv-a', 'Server A').toJson()]),
    });
    final provider = McpProvider(
      contextProvider: () => throw UnimplementedError(),
    );
    await pumpEventQueue();

    // Restore rewrote prefs; reload rebuilds memory + connections.
    SharedPreferences.setMockInitialValues({
      'mcp_servers_v1': jsonEncode([_server('srv-b', 'Server B').toJson()]),
    });
    await provider.reloadFromPrefs();
    await pumpEventQueue();

    // A refresh triggered after the reload runs against the new client (or
    // none) and must not resurrect the pre-restore servers on disk.
    await provider.refreshTools('kelivo_subagent');
    await pumpEventQueue();

    expect(await _persistedServerIds(), contains('srv-b'));
    expect(await _persistedServerIds(), isNot(contains('srv-a')));

    for (final s in provider.servers) {
      await provider.disconnect(s.id);
    }
  });
}
