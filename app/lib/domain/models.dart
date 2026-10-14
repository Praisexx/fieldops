import 'job_status.dart';

DateTime _dt(Object? v) => DateTime.parse(v as String);
DateTime? _dtOrNull(Object? v) => v == null ? null : DateTime.parse(v as String);

class RequiredField {
  const RequiredField(this.key, this.label);
  factory RequiredField.fromJson(Map<String, dynamic> j) => RequiredField(j['key'] as String, j['label'] as String);
  final String key;
  final String label;
}

enum SyncState { synced, pending, syncing, failed }

class JobNote {
  const JobNote({required this.id, required this.clientId, required this.body, required this.createdAt, this.sync = SyncState.synced, this.outboxId});
  factory JobNote.fromJson(Map<String, dynamic> j) => JobNote(
        id: j['id'] as String,
        clientId: j['clientId'] as String?,
        body: j['body'] as String,
        createdAt: _dt(j['createdAt']),
      );
  final String id;
  final String? clientId;
  final String body;
  final DateTime createdAt;
  final SyncState sync;
  final int? outboxId;
}

enum EvidenceKind { photo, document, text }

class Evidence {
  const Evidence({
    required this.id,
    required this.clientId,
    required this.kind,
    required this.createdAt,
    this.filename,
    this.mime,
    this.size,
    this.text,
    this.sync = SyncState.synced,
    this.error,
    this.outboxId,
  });
  factory Evidence.fromJson(Map<String, dynamic> j) => Evidence(
        id: j['id'] as String,
        clientId: j['clientId'] as String?,
        kind: EvidenceKind.values.byName(j['kind'] as String),
        filename: j['filename'] as String?,
        mime: j['mime'] as String?,
        size: j['size'] as int?,
        text: j['text'] as String?,
        createdAt: _dt(j['createdAt']),
      );
  final String id;
  final String? clientId;
  final EvidenceKind kind;
  final String? filename;
  final String? mime;
  final int? size;
  final String? text;
  final DateTime createdAt;
  final SyncState sync;
  final String? error;
  final int? outboxId;
}

class StatusEvent {
  const StatusEvent({required this.from, required this.to, required this.occurredAt, this.reason, this.pending = false});
  factory StatusEvent.fromJson(Map<String, dynamic> j) => StatusEvent(
        from: JobStatus.parse(j['fromStatus'] as String),
        to: JobStatus.parse(j['toStatus'] as String),
        reason: j['reason'] as String?,
        occurredAt: _dt(j['occurredAt']),
      );
  final JobStatus from;
  final JobStatus to;
  final String? reason;
  final DateTime occurredAt;
  final bool pending;
}

class Job {
  const Job({
    required this.id,
    required this.title,
    required this.type,
    required this.customerName,
    required this.location,
    required this.description,
    required this.status,
    required this.priority,
    required this.assignedAt,
    required this.updatedAt,
    this.customerPhone,
    this.dueDate,
    this.assignedBy,
    this.requiredFields = const [],
    this.formData = const {},
    this.evidenceRequired = 0,
    this.notes = const [],
    this.evidence = const [],
    this.history = const [],
    this.hasDetail = false,
  });

  factory Job.fromJson(Map<String, dynamic> j) => Job(
        id: j['id'] as String,
        title: j['title'] as String,
        type: j['type'] as String,
        customerName: j['customerName'] as String,
        customerPhone: j['customerPhone'] as String?,
        location: j['location'] as String,
        description: j['description'] as String,
        status: JobStatus.parse(j['status'] as String),
        priority: JobPriority.parse(j['priority'] as String),
        dueDate: _dtOrNull(j['dueDate']),
        assignedBy: j['assignedBy'] as String?,
        assignedAt: _dt(j['assignedAt']),
        updatedAt: _dt(j['updatedAt']),
        requiredFields: [for (final f in (j['requiredFields'] as List? ?? const [])) RequiredField.fromJson(Map<String, dynamic>.from(f as Map))],
        formData: Map<String, dynamic>.from(j['formData'] as Map? ?? const {}),
        evidenceRequired: j['evidenceRequired'] as int? ?? 0,
        notes: [for (final n in (j['notes'] as List? ?? const [])) JobNote.fromJson(Map<String, dynamic>.from(n as Map))],
        evidence: [for (final e in (j['evidence'] as List? ?? const [])) Evidence.fromJson(Map<String, dynamic>.from(e as Map))],
        history: [for (final h in (j['history'] as List? ?? const [])) StatusEvent.fromJson(Map<String, dynamic>.from(h as Map))],
        hasDetail: j.containsKey('notes'),
      );

  final String id;
  final String title;
  final String type;
  final String customerName;
  final String? customerPhone;
  final String location;
  final String description;
  final JobStatus status;
  final JobPriority priority;
  final DateTime? dueDate;
  final String? assignedBy;
  final DateTime assignedAt;
  final DateTime updatedAt;
  final List<RequiredField> requiredFields;
  final Map<String, dynamic> formData;
  final int evidenceRequired;
  final List<JobNote> notes;
  final List<Evidence> evidence;
  final List<StatusEvent> history;

  /// False when only the list item was cached (notes/evidence/history unknown).
  final bool hasDetail;

  Job copyWith({
    JobStatus? status,
    Map<String, dynamic>? formData,
    List<JobNote>? notes,
    List<Evidence>? evidence,
    List<StatusEvent>? history,
  }) =>
      Job(
        id: id,
        title: title,
        type: type,
        customerName: customerName,
        customerPhone: customerPhone,
        location: location,
        description: description,
        status: status ?? this.status,
        priority: priority,
        dueDate: dueDate,
        assignedBy: assignedBy,
        assignedAt: assignedAt,
        updatedAt: updatedAt,
        requiredFields: requiredFields,
        formData: formData ?? this.formData,
        evidenceRequired: evidenceRequired,
        notes: notes ?? this.notes,
        evidence: evidence ?? this.evidence,
        history: history ?? this.history,
        hasDetail: hasDetail,
      );

  /// Same rules the server applies before allowing `completed`. Empty map = OK.
  Map<String, String> completionProblems() {
    final problems = <String, String>{};
    for (final f in requiredFields) {
      final v = formData[f.key];
      if (v == null || '$v'.trim().isEmpty) problems[f.key] = '${f.label} is required';
    }
    if (evidence.length < evidenceRequired) {
      problems['evidence'] = 'Add at least $evidenceRequired evidence item(s) (${evidence.length} added)';
    }
    return problems;
  }
}
