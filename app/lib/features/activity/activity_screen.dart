import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../domain/models.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../dashboard/dashboard_screen.dart' show openJob;

class FeedEntry {
  const FeedEntry(this.job, this.icon, this.text, this.at, {this.pending = false});
  final Job job;
  final IconData icon;
  final String text;
  final DateTime at;
  final bool pending;
}

/// Feed of everything the agent did, newest first, built from cached job details (works offline).
List<FeedEntry> buildFeed(List<Job> jobs) {
  final out = <FeedEntry>[];
  for (final j in jobs) {
    for (final h in j.history) {
      final reason = h.reason == null ? '' : ' · ${h.reason}';
      out.add(FeedEntry(j, h.to.icon, 'Marked ${h.to.label.toLowerCase()}$reason', h.occurredAt, pending: h.pending));
    }
    for (final n in j.notes) {
      out.add(FeedEntry(j, Icons.notes, 'Note: ${n.body}', n.createdAt, pending: n.sync != SyncState.synced));
    }
    for (final e in j.evidence) {
      final what = switch (e.kind) { EvidenceKind.photo => 'Photo', EvidenceKind.document => 'Document', EvidenceKind.text => 'Text evidence' };
      out.add(FeedEntry(j, Icons.attach_file, '$what added', e.createdAt, pending: e.sync != SyncState.synced));
    }
  }
  out.sort((a, b) => b.at.compareTo(a.at));
  return out;
}

class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: jobs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(jobsProvider)),
        data: (list) {
          final feed = buildFeed(list);
          final body = feed.isEmpty
              ? LayoutBuilder(
                  builder: (_, c) => ListView(children: [
                    SizedBox(height: c.maxHeight, child: const EmptyState(icon: Icons.history, title: 'No activity yet', message: 'Status changes, notes and evidence you add will be listed here.')),
                  ]),
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: feed.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = feed[i];
                    return ListTile(
                      leading: CircleAvatar(backgroundColor: e.job.status.color.withValues(alpha: 0.12), child: Icon(e.icon, color: readable(context, e.job.status.color), size: 20)),
                      title: Text(e.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${e.job.title}\n${formatDateTime(e.at)}${e.pending ? ' · waiting to sync' : ''}', maxLines: 3, overflow: TextOverflow.ellipsis),
                      isThreeLine: true,
                      onTap: () => openJob(context, e.job.id),
                    );
                  },
                );
          return ContentWidth(child: RefreshIndicator(onRefresh: () => ref.read(syncProvider.notifier).pull(), child: body));
        },
      ),
    );
  }
}
