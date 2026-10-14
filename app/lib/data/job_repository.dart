import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/app_exception.dart';
import '../domain/job_status.dart';
import '../domain/models.dart';
import '../domain/outbox.dart';
import 'api_client.dart';
import 'local_db.dart';
import 'sync_service.dart';

const maxEvidenceBytes = 10 * 1024 * 1024;
const _noteMax = 2000;
const _uuid = Uuid();

/// Single source of truth for job data. Screens read the local cache (+ pending actions) and never wait
/// on the network; writes go to the outbox first and are synced in the background.
class JobRepository {
  JobRepository({required this.api, required this.db, required this.filesDir, this.onChanged, void Function(String, double?)? onProgress}) {
    sync = SyncService(api: api, db: db, onChanged: onChanged, onProgress: onProgress, afterJobSynced: refreshJob);
  }

  final ApiClient api;
  final LocalDb db;
  final Directory filesDir;
  final void Function()? onChanged;
  late final SyncService sync;

  // ---- reads (local) ----
  Future<List<Job>> jobs() async {
    final pending = await db.outbox();
    return [
      for (final j in await db.jobs()) applyOutbox(Job.fromJson(j), pending.where((o) => o.jobId == j['id'])),
    ];
  }

  Future<Job?> job(String id) async {
    final raw = await db.job(id);
    if (raw == null) return null;
    return applyOutbox(Job.fromJson(raw), (await db.outbox()).where((o) => o.jobId == id));
  }

  Future<List<OutboxItem>> outbox() => db.outbox();

  // ---- reads (network → cache) ----
  /// Pulls the list, then every job's detail so notes/evidence/history are available offline.
  Future<void> refreshAll() async {
    final list = await api.listJobs();
    await db.replaceJobs(list);
    onChanged?.call();
    final stale = <String>[
      for (final j in list)
        if ((await db.job(j['id'] as String))?.containsKey('notes') != true) j['id'] as String,
    ];
    for (var i = 0; i < stale.length; i += 4) {
      await Future.wait(stale.skip(i).take(4).map((id) => refreshJob(id).catchError((_) {})));
    }
    await db.setMeta('lastRefresh', DateTime.now().toUtc().toIso8601String());
    onChanged?.call();
  }

  Future<void> refreshJob(String id) async {
    final raw = await api.getJob(id);
    await db.upsertJob(raw);
    onChanged?.call();
  }

  Future<DateTime?> lastRefresh() async {
    final v = await db.meta('lastRefresh');
    return v == null ? null : DateTime.parse(v);
  }

  // ---- writes (local first) ----
  Future<void> changeStatus(Job job, JobStatus to, {String? reason}) async {
    if (!job.status.next.contains(to)) {
      throw AppException(ErrorKind.conflict, 'A ${job.status.label.toLowerCase()} job cannot be marked ${to.label.toLowerCase()}.');
    }
    final r = reason?.trim();
    if (to.needsReason && (r == null || r.isEmpty)) {
      throw AppException.validation({'reason': 'Please give a reason'}, 'A reason is required.');
    }
    if (to == JobStatus.completed) {
      final problems = job.completionProblems();
      if (problems.isNotEmpty) throw AppException.validation(problems, 'This job is not ready to complete yet.');
    }
    await _enqueue(job.id, OutboxType.status, {
      'status': to.wire,
      if (r != null && r.isNotEmpty) 'reason': r,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> addNote(Job job, String body) async {
    final b = body.trim();
    _requireWorkable(job);
    if (b.isEmpty) throw AppException.validation({'body': 'Note cannot be empty'});
    if (b.length > _noteMax) throw AppException.validation({'body': 'Notes can be up to $_noteMax characters'});
    await _enqueue(job.id, OutboxType.note, {'body': b});
  }

  Future<void> saveForm(Job job, Map<String, String> answers) async {
    _requireWorkable(job);
    await _enqueue(job.id, OutboxType.form, {'answers': answers});
  }

  Future<void> addTextEvidence(Job job, String text) async {
    _requireWorkable(job);
    final t = text.trim();
    if (t.isEmpty) throw AppException.validation({'text': 'Text cannot be empty'});
    await _enqueue(job.id, OutboxType.evidence, {'kind': 'text', 'text': t});
  }

  /// Copies the picked file into app storage first, so it survives the picker's temp file being cleaned up.
  Future<void> addFileEvidence(Job job, {required EvidenceKind kind, required String sourcePath, required String filename, required String mime}) async {
    _requireWorkable(job);
    final size = await File(sourcePath).length();
    if (size > maxEvidenceBytes) {
      throw const AppException(ErrorKind.tooLarge, 'That file is larger than 10 MB. Choose a smaller one.');
    }
    final clientId = _uuid.v4();
    final dest = localEvidencePath(clientId);
    await Directory(p.dirname(dest)).create(recursive: true);
    await File(sourcePath).copy(dest);
    await _enqueue(job.id, OutboxType.evidence,
        {'kind': kind.name, 'filename': filename, 'mime': mime, 'size': size, 'path': dest},
        clientId: clientId);
  }

  Future<void> deleteEvidence(Job job, Evidence e) async {
    _requireWorkable(job);
    if (e.outboxId != null) {
      // Never reached the server: just drop the queued upload.
      await db.deleteOutbox(e.outboxId!);
      final f = File(localEvidencePath(e.clientId ?? ''));
      if (e.clientId != null && f.existsSync()) await f.delete();
      onChanged?.call();
      return;
    }
    await _enqueue(job.id, OutboxType.evidenceDelete, {'evidenceId': e.id});
  }

  Future<void> retry(int outboxId) async {
    await db.setOutboxState(outboxId, OutboxState.pending);
    onChanged?.call();
    unawaited(sync.flush());
  }

  Future<void> discard(int outboxId) async {
    final item = await db.outboxItem(outboxId);
    if (item?.type == OutboxType.evidence && item!.payload['path'] != null) {
      final f = File(item.payload['path'] as String);
      if (f.existsSync()) await f.delete();
    }
    await db.deleteOutbox(outboxId);
    onChanged?.call();
  }

  String localEvidencePath(String clientId) => p.join(filesDir.path, 'evidence', clientId);

  Future<void> clearAll() async {
    await db.clearAll();
    final dir = Directory(p.join(filesDir.path, 'evidence'));
    if (dir.existsSync()) await dir.delete(recursive: true);
    onChanged?.call();
  }

  void _requireWorkable(Job job) {
    if (!job.status.isWorkable) {
      throw AppException(ErrorKind.conflict, 'Accept this job first. Notes and evidence can only be added to an accepted or in-progress job.');
    }
  }

  Future<void> _enqueue(String jobId, OutboxType type, Map<String, dynamic> payload, {String? clientId}) async {
    await db.enqueue(jobId: jobId, type: type, clientId: clientId ?? _uuid.v4(), payload: payload);
    onChanged?.call();
    unawaited(sync.flush());
  }
}
