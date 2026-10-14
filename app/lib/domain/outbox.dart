import 'dart:convert';

import 'job_status.dart';
import 'models.dart';

enum OutboxType { status, note, form, evidence, evidenceDelete }

enum OutboxState { pending, syncing, failed }

/// A user action recorded locally, waiting to be sent to the server.
class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.jobId,
    required this.type,
    required this.clientId,
    required this.payload,
    required this.state,
    required this.createdAt,
    this.error,
  });

  factory OutboxItem.fromRow(Map<String, Object?> r) => OutboxItem(
        id: r['id'] as int,
        jobId: r['job_id'] as String,
        type: OutboxType.values.byName(r['type'] as String),
        clientId: r['client_id'] as String,
        payload: Map<String, dynamic>.from(jsonDecode(r['payload'] as String) as Map),
        state: OutboxState.values.byName(r['state'] as String),
        error: r['error'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String),
      );

  final int id;
  final String jobId;
  final OutboxType type;
  final String clientId;
  final Map<String, dynamic> payload;
  final OutboxState state;
  final String? error;
  final DateTime createdAt;
}

SyncState _sync(OutboxState s) => switch (s) {
      OutboxState.pending => SyncState.pending,
      OutboxState.syncing => SyncState.syncing,
      OutboxState.failed => SyncState.failed,
    };

/// Server snapshot + the user's not-yet-synced actions = what the screen should show.
///
/// Failed status/form/delete actions are NOT applied (the server rejected them, so the
/// server's state is the truth); failed notes and evidence stay visible with a failed
/// badge so the user can retry or discard instead of silently losing them.
Job applyOutbox(Job base, Iterable<OutboxItem> items) {
  var status = base.status;
  var form = Map<String, dynamic>.from(base.formData);
  final notes = [...base.notes];
  var evidence = [...base.evidence];
  final history = [...base.history];

  for (final item in items) {
    if (item.jobId != base.id) continue;
    final failed = item.state == OutboxState.failed;
    switch (item.type) {
      case OutboxType.status:
        if (failed) break;
        final to = JobStatus.parse(item.payload['status'] as String);
        history.add(StatusEvent(
          from: status,
          to: to,
          reason: item.payload['reason'] as String?,
          occurredAt: DateTime.parse(item.payload['occurredAt'] as String),
          pending: true,
        ));
        status = to;
      case OutboxType.form:
        if (failed) break;
        form.addAll(Map<String, dynamic>.from(item.payload['answers'] as Map));
      case OutboxType.note:
        if (notes.any((n) => n.clientId == item.clientId)) break; // already on the server
        notes.add(JobNote(
          id: 'local-${item.id}',
          clientId: item.clientId,
          body: item.payload['body'] as String,
          createdAt: item.createdAt,
          sync: _sync(item.state),
          outboxId: item.id,
        ));
      case OutboxType.evidence:
        if (evidence.any((e) => e.clientId == item.clientId)) break;
        evidence.add(Evidence(
          id: 'local-${item.id}',
          clientId: item.clientId,
          kind: EvidenceKind.values.byName(item.payload['kind'] as String),
          filename: item.payload['filename'] as String?,
          mime: item.payload['mime'] as String?,
          size: item.payload['size'] as int?,
          text: item.payload['text'] as String?,
          createdAt: item.createdAt,
          sync: _sync(item.state),
          error: item.error,
          outboxId: item.id,
        ));
      case OutboxType.evidenceDelete:
        if (failed) break;
        evidence = evidence.where((e) => e.id != item.payload['evidenceId']).toList();
    }
  }
  return base.copyWith(status: status, formData: form, notes: notes, evidence: evidence, history: history);
}
