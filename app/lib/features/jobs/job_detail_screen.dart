import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_exception.dart';
import '../../core/format.dart';
import '../../domain/job_status.dart';
import '../../domain/models.dart';
import '../../domain/outbox.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'evidence_section.dart';

class JobDetailScreen extends ConsumerStatefulWidget {
  const JobDetailScreen({super.key, required this.jobId});
  final String jobId;
  @override
  ConsumerState<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends ConsumerState<JobDetailScreen> {
  final _controllers = <String, TextEditingController>{};
  final _dirty = <String>{};
  Map<String, String> _problems = {};
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    // Fetch the freshest detail when opened; the cached copy shows immediately.
    Future.microtask(() => ref.read(repositoryProvider).refreshJob(widget.jobId).catchError((_) {}));
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _syncControllers(Job job) {
    for (final f in job.requiredFields) {
      final c = _controllers.putIfAbsent(f.key, () => TextEditingController());
      final v = '${job.formData[f.key] ?? ''}';
      if (!_dirty.contains(f.key) && c.text != v) c.text = v;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _acting = true);
    try {
      await action();
    } catch (e) {
      final ex = AppException.from(e);
      if (mounted) {
        setState(() => _problems = ex.fields);
        showSnack(context, ex.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _change(Job job, JobStatus to) async {
    String? reason;
    if (to.needsReason) {
      reason = await askText(
        context,
        title: switch (to) {
          JobStatus.declined => 'Decline this job?',
          JobStatus.cancelled => 'Cancel this job?',
          _ => 'Report this job as failed?',
        },
        label: 'Reason',
        hint: 'Explain what happened',
        confirm: to.label,
        required: true,
      );
      if (reason == null) return;
    }
    await _run(() async {
      await ref.read(repositoryProvider).changeStatus(job, to, reason: reason);
      if (mounted) {
        setState(() => _problems = {});
        showSnack(context, to == JobStatus.completed ? 'Job completed' : 'Marked ${to.label.toLowerCase()}');
      }
    });
  }

  Future<void> _saveForm(Job job) async {
    final answers = {for (final f in job.requiredFields) f.key: _controllers[f.key]!.text.trim()};
    await _run(() async {
      await ref.read(repositoryProvider).saveForm(job, answers);
      _dirty.clear();
      if (mounted) {
        setState(() => _problems = {});
        showSnack(context, 'Information saved');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(jobProvider(widget.jobId));
    return Scaffold(
      appBar: AppBar(title: const Text('Job details')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(jobProvider(widget.jobId))),
        data: (job) {
          if (job == null) {
            return const EmptyState(icon: Icons.search_off, title: 'Job not found', message: 'It may have been reassigned or removed.');
          }
          _syncControllers(job);
          final outbox = (ref.watch(outboxProvider).value ?? const <OutboxItem>[]).where((o) => o.jobId == job.id).toList();
          final failed = outbox.where((o) => o.state == OutboxState.failed).toList();
          final t = Theme.of(context);
          return ContentWidth(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _Header(job: job),
                const SizedBox(height: 12),
                if (failed.isNotEmpty) ...[_FailedCard(items: failed), const SizedBox(height: 12)],
                _ActionsCard(job: job, busy: _acting, problems: _problems, onChange: (to) => _change(job, to)),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Job information',
                  child: Column(children: [
                    _row(context, Icons.work_outline, 'Type', job.type),
                    _row(context, Icons.person_outline, 'Customer', job.customerName),
                    if (job.customerPhone != null) _row(context, Icons.phone_outlined, 'Phone', job.customerPhone!),
                    _row(context, Icons.place_outlined, 'Location', job.location),
                    if (job.dueDate != null) _row(context, Icons.event_outlined, 'Due', '${formatDate(job.dueDate!)} (${dueLabel(job.dueDate!)})'),
                    if (job.assignedBy != null) _row(context, Icons.badge_outlined, 'Assigned by', '${job.assignedBy} · ${formatDate(job.assignedAt)}'),
                    const Divider(height: 24),
                    Align(alignment: Alignment.centerLeft, child: Text('Instructions', style: t.textTheme.labelLarge)),
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerLeft, child: Text(job.description)),
                  ]),
                ),
                if (job.requiredFields.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SectionCard(
                    title: 'Required information',
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final f in job.requiredFields)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TextField(
                            controller: _controllers[f.key],
                            enabled: job.status.isWorkable && !_acting,
                            maxLength: 1000,
                            maxLines: null,
                            onChanged: (_) => _dirty.add(f.key),
                            decoration: InputDecoration(labelText: f.label, errorText: _problems[f.key], counterText: ''),
                          ),
                        ),
                      if (job.status.isWorkable)
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.tonalIcon(onPressed: _acting ? null : () => _saveForm(job), icon: const Icon(Icons.save_outlined), label: const Text('Save information')),
                        )
                      else if (job.status == JobStatus.assigned)
                        Text('Accept the job to fill this in.', style: t.textTheme.bodySmall),
                    ]),
                  ),
                ],
                const SizedBox(height: 12),
                EvidenceSection(job: job, problem: _problems['evidence']),
                const SizedBox(height: 12),
                NotesSection(job: job),
                const SizedBox(height: 12),
                _History(job: job),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          SizedBox(width: 92, child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
          Expanded(child: Text(value)),
        ]),
      );
}

/// Dialog asking for free text (reason / note / text evidence). Returns null when cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String? hint,
  String confirm = 'Save',
  bool required = false,
  int maxLength = 500,
}) {
  final c = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 4,
          minLines: 2,
          maxLength: maxLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: label, hintText: hint, errorText: error),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (required && c.text.trim().isEmpty) {
                setState(() => error = '$label is required');
                return;
              }
              Navigator.pop(ctx, c.text.trim());
            },
            child: Text(confirm),
          ),
        ],
      ),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.job});
  final Job job;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final stages = [JobStatus.assigned, JobStatus.accepted, JobStatus.inProgress, JobStatus.completed];
    final terminalBad = {JobStatus.declined, JobStatus.cancelled, JobStatus.failed}.contains(job.status);
    final current = stages.indexOf(job.status);
    final reason = terminalBad && job.history.isNotEmpty ? job.history.last.reason : null;
    final pending = job.history.any((h) => h.pending);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            StatusChip(job.status),
            const SizedBox(width: 10),
            PriorityTag(job.priority),
            const Spacer(),
            if (pending) Tooltip(message: 'Waiting to sync', child: Icon(Icons.cloud_upload_outlined, size: 18, color: t.colorScheme.outline)),
          ]),
          const SizedBox(height: 12),
          Text(job.title, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          if (terminalBad)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: job.status.color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(job.status.icon, color: job.status.color),
                const SizedBox(width: 10),
                Expanded(child: Text(reason == null || reason.isEmpty ? 'This job was ${job.status.label.toLowerCase()}.' : 'This job was ${job.status.label.toLowerCase()}: $reason')),
              ]),
            )
          else
            Semantics(
              label: 'Progress: ${job.status.label}, step ${current + 1} of ${stages.length}',
              excludeSemantics: true,
              child: Row(children: [
                for (var i = 0; i < stages.length; i++) ...[
                  Expanded(
                    child: Column(children: [
                      Container(height: 6, decoration: BoxDecoration(color: i <= current ? job.status.color : t.colorScheme.outlineVariant, borderRadius: BorderRadius.circular(3))),
                      const SizedBox(height: 4),
                      Text(stages[i].label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelSmall?.copyWith(fontWeight: i == current ? FontWeight.w700 : FontWeight.w400)),
                    ]),
                  ),
                  if (i < stages.length - 1) const SizedBox(width: 6),
                ],
              ]),
            ),
        ]),
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({required this.job, required this.busy, required this.problems, required this.onChange});
  final Job job;
  final bool busy;
  final Map<String, String> problems;
  final void Function(JobStatus) onChange;

  @override
  Widget build(BuildContext context) {
    if (!job.status.isOpen) return const SizedBox.shrink();
    final t = Theme.of(context);
    final remaining = job.completionProblems();
    Widget btn(String label, IconData icon, JobStatus to, {bool primary = true}) {
      final style = primary
          ? FilledButton.styleFrom(minimumSize: const Size.fromHeight(48))
          : OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48));
      final onPressed = busy ? null : () => onChange(to);
      return primary
          ? FilledButton.icon(style: style, onPressed: onPressed, icon: Icon(icon), label: Text(label))
          : OutlinedButton.icon(style: style, onPressed: onPressed, icon: Icon(icon), label: Text(label));
    }

    return SectionCard(
      title: 'Next step',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        switch (job.status) {
          JobStatus.assigned => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('This job is waiting for your response.'),
              const SizedBox(height: 12),
              btn('Accept job', Icons.check, JobStatus.accepted),
              const SizedBox(height: 8),
              btn('Decline', Icons.block, JobStatus.declined, primary: false),
            ]),
          JobStatus.accepted => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text("You've accepted this job. Start when you're on site."),
              const SizedBox(height: 12),
              btn('Start job', Icons.play_arrow, JobStatus.inProgress),
              const SizedBox(height: 8),
              btn('Cancel job', Icons.cancel_outlined, JobStatus.cancelled, primary: false),
            ]),
          _ => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (remaining.isEmpty)
                Row(children: [
                  Icon(Icons.check_circle, color: JobStatus.completed.color, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('Everything required is in. You can complete this job.')),
                ])
              else ...[
                Text('Before you can complete:', style: t.textTheme.labelLarge),
                const SizedBox(height: 6),
                for (final m in remaining.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.radio_button_unchecked, size: 16, color: t.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(child: Text(m)),
                    ]),
                  ),
              ],
              const SizedBox(height: 12),
              btn('Complete job', Icons.task_alt, JobStatus.completed),
              const SizedBox(height: 8),
              btn('Report failure', Icons.error_outline, JobStatus.failed, primary: false),
            ]),
        },
      ]),
    );
  }
}

class _FailedCard extends ConsumerWidget {
  const _FailedCard({required this.items});
  final List<OutboxItem> items;

  String _what(OutboxItem i) => switch (i.type) {
        OutboxType.status => 'Status change to ${JobStatus.parse(i.payload['status'] as String).label.toLowerCase()}',
        OutboxType.note => 'Note',
        OutboxType.form => 'Required information',
        OutboxType.evidence => i.payload['kind'] == 'text' ? 'Text evidence' : 'Evidence "${i.payload['filename'] ?? 'file'}"',
        OutboxType.evidenceDelete => 'Evidence removal',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final repo = ref.read(repositoryProvider);
    return Card(
      color: t.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.sync_problem, color: t.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Text('Could not sync', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onErrorContainer, fontWeight: FontWeight.w700)),
          ]),
          for (final i in items) ...[
            const SizedBox(height: 10),
            Text(_what(i), style: TextStyle(color: t.colorScheme.onErrorContainer, fontWeight: FontWeight.w600)),
            Text(i.error ?? 'The server rejected this change.', style: TextStyle(color: t.colorScheme.onErrorContainer)),
            Wrap(spacing: 8, children: [
              TextButton(onPressed: () => repo.retry(i.id), child: const Text('Retry')),
              TextButton(onPressed: () => repo.discard(i.id), child: const Text('Discard')),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.job});
  final Job job;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final items = job.history.reversed.toList();
    return SectionCard(
      title: 'Status history',
      child: items.isEmpty
          ? Text(job.hasDetail ? 'No changes yet.' : 'Connect to the internet to load history.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))
          : Column(children: [
              for (final h in items)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(h.to.icon, color: h.to.color),
                  title: Text('${h.from.label} → ${h.to.label}${h.pending ? ' (waiting to sync)' : ''}'),
                  subtitle: Text([formatDateTime(h.occurredAt), if (h.reason != null) h.reason!].join('\n')),
                ),
            ]),
    );
  }
}
