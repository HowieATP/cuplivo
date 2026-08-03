import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_service.dart';
import '../backup/data_sync.dart';
import '../../models/backup.dart';
import '../../models/conversation.dart';
import '../../models/incremental_backup.dart';
import 'lan_sync_logic.dart';
import 'lan_sync_models.dart';

/// Callback for delivering the received zip file to the UI for restore + restart.
typedef SyncServerZipReceivedCallback = Future<void> Function(File zipFile);

/// HTTP server for LAN sync. Single-use lifecycle.
///
/// Protocol (two round trips):
/// 1. POST /sync/plan  → initiator sends SyncIndex, server returns SyncPlan.
/// 2. POST /sync/exchange → initiator sends its incremental zip, server
///    responds with its own incremental zip. Both sides then apply + restart.
class LanSyncServer extends ChangeNotifier {
  final ChatService _chatService;
  final DataSync _dataSync;

  HttpServer? _server;
  String? _pin;
  String? _address;
  int? _port;

  /// Whether the server is listening.
  bool _running = false;
  bool get running => _running;

  /// The 4-digit PIN for this session. Null when not running.
  String? get pin => _pin;

  /// The displayed address (IP:port). Null when not running.
  String? get address => _address;
  int? get port => _port;

  /// Current status message for UI display.
  String _status = '';
  String get status => _status;

  /// Called when the initiator's zip arrives and has been saved to disk.
  /// The UI is responsible for merge-restoring and restarting.
  SyncServerZipReceivedCallback? onZipReceived;

  /// The received zip file path, for the UI to restore after sending the
  /// response back.
  File? _receivedZip;
  File? get receivedZip => _receivedZip;

  LanSyncServer({required this._chatService, required this._dataSync});

  /// Starts the HTTP server. Returns the address string (IP:port) or throws.
  Future<String> start({int preferredPort = 9527}) async {
    if (_running) throw Exception('Server already running');

    _pin = _generatePin();

    // Bind to all interfaces (0.0.0.0) so LAN peers can connect.
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      // Port in use → fallback to random port.
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    _port = server.port;
    _address = await _getLocalIp();
    _running = true;
    _status = 'Listening on $_address:$_port';
    notifyListeners();

    _handleRequests(server);
    return '$_address:$_port';
  }

  /// Stops the server and cleans up.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _running = false;
    _pin = null;
    _address = null;
    _port = null;
    _status = '';
    _receivedZip = null;
    notifyListeners();
  }

  Future<void> _handleRequests(HttpServer server) async {
    await for (final request in server) {
      try {
        final peer = request.connectionInfo?.remoteAddress.address;
        debugPrint(
          'LanSyncServer ${request.method} ${request.uri.path} from $peer',
        );
        final path = request.uri.path;
        // PIN validation on every request.
        if (!validatePin(request.headers.value('X-Sync-Pin'))) {
          request.response
            ..statusCode = HttpStatus.unauthorized
            ..write('Invalid PIN');
          await request.response.close();
          continue;
        }

        if (path == '/sync/plan' && request.method == 'POST') {
          await _handlePlan(request);
        } else if (path == '/sync/exchange' && request.method == 'POST') {
          await _handleExchange(request);
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not found');
          await request.response.close();
        }
      } catch (e) {
        debugPrint('LanSyncServer request error: $e');
        try {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('Server error: $e');
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  /// Round 1: Receive the initiator's index, compute sync plan, return it.
  Future<void> _handlePlan(HttpRequest request) async {
    final body = await _readBody(request);
    final index = SyncIndex.fromJsonString(body);

    // Build the server's own index.
    final myConversations = _chatService.getAllCompleteConversations();
    final myAssistantIds = (await _chatService.getAllAssistants())
        .map((a) => a.id)
        .toList();

    final plan = _computePlan(
      initiatorIndex: index,
      myConversations: myConversations,
      myAssistantIds: myAssistantIds,
    );

    _status =
        'Sync plan sent: '
        '${plan.initiatorOnlyCount} to receive, '
        '${plan.serverOnlyCount} to send, '
        '${plan.forkCount} forks';
    notifyListeners();

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(plan.toJsonString());
    await request.response.close();
  }

  /// Round 2: Receive the initiator's zip, save it, then build and return
  /// the server's own zip.
  Future<void> _handleExchange(HttpRequest request) async {
    final contentType = request.headers.contentType;
    if (contentType == null ||
        contentType.mimeType != 'multipart/form-data' ||
        contentType.parameters['boundary'] == null) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Expected multipart/form-data');
      await request.response.close();
      return;
    }

    final boundary = contentType.parameters['boundary']!;
    final parts = await _parseMultipart(request, boundary);
    final zipPart = parts['zip'];

    // zipPart may be null when the initiator has no increments to send
    // (all conversations are identical or server-only). This is not an
    // error — proceed without a received zip.
    File? receivedFile;
    if (zipPart != null) {
      // Save the received zip to a temp file.
      final tmpDir = await _getTempDir();
      final receivedPath = p.join(
        tmpDir.path,
        'lan_sync_received_${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      receivedFile = File(receivedPath);
      await receivedFile.writeAsBytes(zipPart);

      _status =
          'Received zip (${zipPart.length} bytes). Building response zip...';
      notifyListeners();
    } else {
      _status = 'No zip received from initiator. Building response zip...';
      notifyListeners();
    }

    // Determine the `since` for building our zip.
    // Re-parse the plan from the request body if available, otherwise
    // we need the initiator to send the plan's `since` along with the zip.
    final planSinceStr = parts['since'];
    DateTime? since;
    if (planSinceStr != null) {
      try {
        since = DateTime.parse(utf8.decode(planSinceStr));
      } catch (e) {
        debugPrint('Failed to parse since: $e');
      }
    }

    // Build the server's incremental zip.
    final cfg = const WebDavConfig(includeChats: true, includeFiles: true);
    File? myZip;
    if (since != null) {
      final incremental = IncrementalBackupConfig(
        since: since,
        includeSettings: false,
        includeFiles: true,
        updateBackupTime: false,
      );
      myZip = await _dataSync.exportToFile(cfg, incremental: incremental);
    }

    _receivedZip = receivedFile;
    _status = 'Response zip ready. Waiting for apply.';
    notifyListeners();

    // Send our zip as the response.
    if (myZip != null && await myZip.exists()) {
      final zipBytes = await myZip.readAsBytes();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set('Content-Type', 'application/zip')
        ..add(zipBytes);
      await request.response.close();
      // Clean up our zip temp file.
      try {
        await myZip.delete();
      } catch (_) {}
    } else {
      // No increment to send — respond with empty body.
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{"empty":true}');
      await request.response.close();
    }

    // Notify the UI that a zip was received and should be restored.
    // Only restore if we actually received a zip from the initiator.
    if (receivedFile != null && onZipReceived != null) {
      await onZipReceived!(receivedFile);
    }
  }

  /// Computes the sync plan by comparing the initiator's index with our data.
  SyncPlan _computePlan({
    required SyncIndex initiatorIndex,
    required List<Conversation> myConversations,
    required List<String> myAssistantIds,
  }) {
    final plans = <SyncConvPlan>[];

    final myConvsById = <String, Conversation>{};
    for (final c in myConversations) {
      myConvsById[c.id] = c;
    }

    // Check conversations that the initiator has.
    for (final entry in initiatorIndex.conversations.entries) {
      final convId = entry.key;
      final theirMsgIds = entry.value;
      final myConv = myConvsById[convId];

      if (myConv == null) {
        // Conversation doesn't exist on our side — initiator-only.
        plans.add(
          SyncConvPlan(
            conversationId: convId,
            conversationTitle: null,
            state: SyncConvState.initiatorOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: theirMsgIds.length,
            serverIncrementCount: 0,
          ),
        );
        continue;
      }

      // Get our message IDs for this conversation.
      final myMsgIds = _chatService.repo.getMessageIdsSync(convId);
      plans.add(
        computeConvPlan(
          ConvPlanInput(
            conversationId: convId,
            conversationTitle: myConv.title,
            initiatorMsgIds: theirMsgIds,
            serverMsgIds: myMsgIds,
          ),
        ),
      );
    }

    // Check conversations that only we have (server-only, no fork point).
    for (final c in myConversations) {
      final convId = c.id;
      if (!initiatorIndex.conversations.containsKey(convId)) {
        final myMsgIds = _chatService.repo.getMessageIdsSync(convId);
        plans.add(
          SyncConvPlan(
            conversationId: convId,
            conversationTitle: c.title,
            state: SyncConvState.serverOnly,
            forkPointMessageId: null,
            initiatorIncrementCount: 0,
            serverIncrementCount: myMsgIds.length,
          ),
        );
      }
    }

    // Compute earliest `since` timestamp using the pure logic function.
    // The timestamp lookup accesses our local DB for fork-point messages.
    final since = computeEarliestSince(plans, (convId, forkPointId) {
      final msg = _chatService.repo.getMessageSync(forkPointId);
      return msg?.timestamp;
    });

    // Assistant set differences.
    final theirSet = initiatorIndex.assistantIds.toSet();
    final mySet = myAssistantIds.toSet();
    final missingOnServer = theirSet.difference(mySet).toList();
    final missingOnInitiator = mySet.difference(theirSet).toList();

    return SyncPlan(
      conversations: plans,
      missingAssistantIds: missingOnServer,
      remoteMissingAssistantIds: missingOnInitiator,
      since: since,
    );
  }

  bool validatePin(String? provided) {
    if (_pin == null) return false;
    return provided == _pin;
  }

  static String _generatePin() {
    final rng = DateTime.now().microsecondsSinceEpoch;
    final code = rng % 10000;
    return code.toString().padLeft(4, '0');
  }

  static Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      debugPrint('Failed to get local IP: $e');
    }
    return '127.0.0.1';
  }

  Future<Directory> _getTempDir() async {
    final tmp = Directory.systemTemp;
    final dir = Directory(p.join(tmp.path, 'cuplivo_lan_sync'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _readBody(HttpRequest request) async {
    final completer = Completer<String>();
    final buffer = <int>[];
    await for (final chunk in request) {
      buffer.addAll(chunk);
    }
    completer.complete(utf8.decode(buffer));
    return completer.future;
  }

  Future<Map<String, List<int>>> _parseMultipart(
    HttpRequest request,
    String boundary,
  ) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
    }
    return parseMultipartBytes(bytes, boundary);
  }
}
