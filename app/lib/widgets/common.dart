import 'package:flutter/material.dart';

import '../core/app_exception.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../domain/job_status.dart';
import '../domain/models.dart';

/// Status/priority colours are tuned for light surfaces; lift their lightness on dark ones so text stays readable.
Color readable(BuildContext context, Color c) {
  if (Theme.of(context).brightness != Brightness.dark) return c;
  final hsl = HSLColor.fromColor(c);
  return hsl.withLightness(hsl.lightness < 0.72 ? 0.72 : hsl.lightness).withSaturation((hsl.saturation * 0.9).clamp(0, 1)).toColor();
}

/// Centres content and caps its width on tablets / landscape.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: kMaxContentWidth), child: child),
      );
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final JobStatus status;
  @override
  Widget build(BuildContext context) {
    final c = readable(context, status.color);
    return Semantics(
      label: 'Status: ${status.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(status.icon, size: 14, color: c),
          const SizedBox(width: 4),
          Text(status.label, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class PriorityTag extends StatelessWidget {
  const PriorityTag(this.priority, {super.key});
  final JobPriority priority;
  @override
  Widget build(BuildContext context) {
    final c = readable(context, priority.color);
    return Semantics(
      label: 'Priority: ${priority.label}',
      excludeSemantics: true,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.flag, size: 14, color: c),
        const SizedBox(width: 2),
        Text(priority.label, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class JobCard extends StatelessWidget {
  const JobCard({super.key, required this.job, required this.onTap, this.hasPending = false});
  final Job job;
  final VoidCallback onTap;
  final bool hasPending;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final due = job.dueDate;
    final overdue = due != null && job.status.isOpen && due.isBefore(DateTime.now());
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              StatusChip(job.status),
              const SizedBox(width: 10),
              PriorityTag(job.priority),
              const Spacer(),
              if (hasPending)
                Tooltip(message: 'Waiting to sync', child: Icon(Icons.cloud_upload_outlined, size: 18, color: t.colorScheme.outline)),
            ]),
            const SizedBox(height: 10),
            Text(job.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            _line(context, Icons.person_outline, job.customerName),
            _line(context, Icons.place_outlined, job.location),
            if (due != null)
              _line(context, Icons.event_outlined, '${dueLabel(due)} · ${formatDate(due)}', color: overdue ? t.colorScheme.error : null),
          ]),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, IconData icon, String text, {Color? color}) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: 6),
        Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c))),
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: t.colorScheme.outline),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: t.textTheme.titleMedium),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message!, textAlign: TextAlign.center, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ]),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final e = AppException.from(error);
    final offline = e.kind == ErrorKind.network || e.kind == ErrorKind.timeout;
    return EmptyState(
      icon: offline ? Icons.cloud_off_outlined : Icons.error_outline,
      title: offline ? "Can't reach the server" : 'Something went wrong',
      message: e.message,
      action: FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
    );
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
  ));
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Semantics(header: true, child: Text(title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)))),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: 10),
          child,
        ]),
      ),
    );
  }
}
