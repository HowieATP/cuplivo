import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../chat/chat_service.dart';
import '../backup/data_sync.dart';
import '../../models/backup.dart';
import '../../models/incremental_backup.dart';
import 'lan_sync_models.dart';

/// Callback for delivering the received zip file to the UI for restore + restart.
typedef SyncClientZipReceivedCallback = Future<void> Function(File zipFile);

/// Client-side logic for the LAN sync initiator (device A).
///
/// Protocol (two round trips):
/// 1. POST /sync/plan  → send our index, receive sync plan.
/// 2. POST /sync/exchange → send our incremental zip, receive server's zip.
/// Both sides then apply + restart independently.
class LanSyncClient extends ChangeNotifier {
  final ChatService _chatService;
  final DataSync _dataSync;

  /// Current status message for UI display.
  String _status = '';
  String get status => _status;

  /// The last computed sync plan (null until round 1 completes).
  SyncPlan? _plan;
  SyncPlan? get plan => _plan;

  /// Whether a sync operation is in progress.
  bool _busy = false;
  bool get busy => _busy;

  /// Called when the server's zip arrives and has been saved to disk.
  SyncClientZipReceivedCallback? onZipReceived;

  LanSyncClient({required this._chatService, required this._dataSync});

  /// Builds an HTTP URI, wrapping IPv6 hosts in brackets as required by RFC 3986.
  static String _buildUri(String host, int port, String path) {
    final wrappedHost = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return 'http://$wrappedHost:$port$path';
  }

  /// Round 1: Connect to the server, send our index, get back the sync plan.
  ///
  /// Returns the plan for the UI to display. The user confirms before
  /// proceeding to [exchange].
  Future<SyncPlan> negotiate({
    required String host,
    required int port,
    required String pin,
  }) async {
    _busy = true;
    _status = 'Connecting to $host:$port...';
    notifyListeners();

    try {
      final index = await _buildIndex();
      _status = 'Sending index...';
      notifyListeners();

      final uri = Uri.parse(_buildUri(host, port, '/sync/plan'));
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json', 'X-Sync-Pin': pin},
            body: index.toJsonString(),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 401) {
        throw Exception('Invalid PIN');
      }
      if (response.statusCode != 200) {
        throw Exception(
          'Plan request failed: ${response.statusCode} ${response.body}',
        );
      }

      final plan = SyncPlan.fromJsonString(response.body);
      _plan = plan;
      _status =
          'Sync plan received: '
          '${plan.initiatorOnlyCount} to send, '
          '${plan.serverOnlyCount} to receive, '
          '${plan.forkCount} forks';
      notifyListeners();
      return plan;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Round 2: Build our incremental zip, send it, receive the server's zip.
  /// Both sides then apply independently.
  Future<void> exchange({
    required String host,
    required int port,
    required String pin,
  }) async {
    final plan = _plan;
    if (plan == null) {
      throw Exception('No sync plan available. Run negotiate first.');
    }

    _busy = true;
    _status = 'Building incremental zip...';
    notifyListeners();

    try {
      // Build our incremental zip using the plan's `since`.
      File? myZip;
      if (plan.since != null) {
        final cfg = const WebDavConfig(includeChats: true, includeFiles: true);
        final incremental = IncrementalBackupConfig(
          since: plan.since!,
          includeSettings: false,
          includeFiles: true,
          updateBackupTime: false,
        );
        myZip = await _dataSync.exportToFile(cfg, incremental: incremental);
      }

      _status = 'Sending zip to server...';
      notifyListeners();

      final uri = Uri.parse(_buildUri(host, port, '/sync/exchange'));
      final request = http.MultipartRequest('POST', uri)
        ..headers['X-Sync-Pin'] = pin;

      if (myZip != null && await myZip.exists()) {
        request.files.add(await http.MultipartFile.fromPath('zip', myZip.path));
      }
      if (plan.since != null) {
        request.fields['since'] = plan.since!.toIso8601String();
      }

      final streamedResponse = await request.send().timeout(
        const Duration(minutes: 10),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 401) {
        throw Exception('Invalid PIN');
      }
      if (response.statusCode != 200) {
        throw Exception(
          'Exchange failed: ${response.statusCode} ${response.body}',
        );
      }

      // Check if the response is an empty marker.
      final contentType = response.headers['content-type'] ?? '';
      if (contentType.contains('application/json') &&
          response.body.contains('"empty"')) {
        _status = 'No data to receive from server.';
        notifyListeners();
      } else {
        // Save the server's zip to a temp file.
        final tmpDir = await _getTempDir();
        final receivedPath = p.join(
          tmpDir.path,
          'lan_sync_received_${DateTime.now().millisecondsSinceEpoch}.zip',
        );
        final receivedFile = File(receivedPath);
        await receivedFile.writeAsBytes(response.bodyBytes);

        _status =
            'Received zip (${response.bodyBytes.length} bytes). Ready to apply.';
        notifyListeners();

        // Notify the UI to restore.
        if (onZipReceived != null) {
          await onZipReceived!(receivedFile);
        }
      }

      // Clean up our zip temp file.
      if (myZip != null) {
        try {
          await myZip.delete();
        } catch (_) {}
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Builds our SyncIndex from the current data.
  Future<SyncIndex> _buildIndex() async {
    final conversations = _chatService.getAllCompleteConversations();
    final convMap = <String, List<String>>{};
    for (final conv in conversations) {
      convMap[conv.id] = _chatService.repo.getMessageIdsSync(conv.id);
    }
    final assistantIds = (await _chatService.getAllAssistants())
        .map((a) => a.id)
        .toList();
    return SyncIndex(conversations: convMap, assistantIds: assistantIds);
  }

  Future<Directory> _getTempDir() async {
    final tmp = Directory.systemTemp;
    final dir = Directory(p.join(tmp.path, 'cuplivo_lan_sync'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Resets the client state for a new sync session.
  void reset() {
    _plan = null;
    _status = '';
    _busy = false;
    notifyListeners();
  }
}
