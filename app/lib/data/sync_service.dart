import 'dart:async';
import 'dart:io';

import '../core/app_exception.dart';
import '../domain/outbox.dart';
import 'api_client.dart';
import 'local_db.dart';

class FlushResult {
  const FlushResult({this.sent = 0, this.failed = 0, this.error});
  final int sent;
  final int failed;

  /// Set when the run stopped early (offline, server down, session expired).
  final AppException? error;
}

/// Replays the outbox against the server in the order the user acted.
///
/// - Network/timeout/5xx: stop, keep the item pending, retry later.
/// - 4xx rejection (conflict, validation, ...): mark the item failed so the user can retry or discard,
///   then carry on with the rest of the queue.
/// - Every request carries the action's clientId, so a retry after a lost response never duplicates data.
class SyncService {
  SyncService({required this.api, required this.db, this.onChanged, this.onProgress, this.afterJobSynced});

  final ApiClient api;
  final LocalDb db;
  final void Function()? onChanged;
  final void Function(String clientId, double? progress)? onProgress;

  /// Lets the repository refresh a job from the server once its queued changes landed.
  final Future<void> Function(String jobId)? afterJobSynced;

  Future<FlushResult>? _running;
  bool _again = false;

  Future<FlushResult> flush() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  Future<FlushResult> _loop() async {
    var sent = 0, failed = 0;
    AppException? error;
    do {
      _again = false;
      await db.resetSyncing();
      final touched = <String>{};
      for (final item in await db.outbox(state: OutboxState.pending)) {
        await db.setOutboxState(item.id, OutboxState.syncing);
        onChanged?.call();
        try {
          await _send(item);
          await db.deleteOutbox(item.id);
          touched.add(item.jobId);
          sent++;
        } catch (e) {
          final ex = AppException.from(e);
          if (ex.isTransient || ex.kind == ErrorKind.sessionExpired) {
            await db.setOutboxState(item.id, OutboxState.pending, error: ex.message);
            error = ex;
            break;
          }
          await db.setOutboxState(item.id, OutboxState.failed, error: ex.message);
          touched.add(item.jobId);
          failed++;
        } finally {
          onProgress?.call(item.clientId, null);
          onChanged?.call();
        }
      }
      for (final id in touched) {
        try {
          await afterJobSynced?.call(id);
        } catch (_) {
          // Refresh is best-effort; the next pull will catch up.
        }
      }
      onChanged?.call();
      if (error != null) break;
    } while (_again);
    return FlushResult(sent: sent, failed: failed, error: error);
  }

  Future<void> _send(OutboxItem i) async {
    final p = i.payload;
    switch (i.type) {
      case OutboxType.status:
        await api.postStatus(i.jobId,
            status: p['status'] as String, reason: p['reason'] as String?, clientId: i.clientId, occurredAt: p['occurredAt'] as String);
      case OutboxType.note:
        await api.postNote(i.jobId, body: p['body'] as String, clientId: i.clientId);
      case OutboxType.form:
        await api.putForm(i.jobId, Map<String, dynamic>.from(p['answers'] as Map));
      case OutboxType.evidence:
        final path = p['path'] as String?;
        if (path != null && !File(path).existsSync()) {
          throw const AppException(ErrorKind.validation, 'The file is no longer on this device.');
        }
        await api.uploadEvidence(
          i.jobId,
          kind: p['kind'] as String,
          clientId: i.clientId,
          text: p['text'] as String?,
          filePath: path,
          filename: p['filename'] as String?,
          mime: p['mime'] as String?,
          onProgress: (v) => onProgress?.call(i.clientId, v),
        );
      case OutboxType.evidenceDelete:
        try {
          await api.deleteEvidence(i.jobId, p['evidenceId'] as String);
        } on AppException catch (e) {
          if (e.kind != ErrorKind.notFound) rethrow; // already gone = done
        }
    }
  }
}
