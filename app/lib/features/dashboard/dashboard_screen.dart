import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/job_status.dart';
import '../../domain/outbox.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../jobs/job_detail_screen.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    final sync = ref.watch(syncProvider);
    final session = ref.watch(authProvider).value;
    final t = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(session == null ? 'Dashboard' : 'Hi, ${session.name.split(' ').first}'),
        actions: [
          IconButton(
            tooltip: 'Account',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => _accountSheet(context, ref),
          ),
        ],
      ),
      body: jobs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(jobsProvider)),
        data: (list) {
          if (list.isEmpty) {
            if (!sync.loadedOnce) {
              return sync.error != null
                  ? ErrorState(error: sync.error!, onRetry: () => ref.read(syncProvider.notifier).pull())
                  : const Center(child: CircularProgressIndicator());
            }
            return RefreshIndicator(
              onRefresh: () => ref.read(syncProvider.notifier).pull(),
              child: LayoutBuilder(
                builder: (_, c) => ListView(children: [
                  SizedBox(
                    height: c.maxHeight,
                    child: const EmptyState(
                      icon: Icons.inbox_outlined,
                      title: 'No assignments yet',
                      message: "When a job is assigned to you it will show up here. Pull down to check for new work.",
                    ),
                  ),
                ]),
              ),
            );
          }
          int count(JobStatus s) => list.where((j) => j.status == s).length;
          final important = (list.where((j) => j.status.isOpen).toList()..sort(compareJobs)).take(4).toList();
          final recent = (list.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt))).take(4).toList();
          final closed = list.where((j) => !j.status.isOpen && j.status != JobStatus.completed).length;
          final pendingIds = (ref.watch(outboxProvider).value ?? const <OutboxItem>[]).map((o) => o.jobId).toSet();

          return RefreshIndicator(
            onRefresh: () => ref.read(syncProvider.notifier).pull(),
            child: ContentWidth(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  LayoutBuilder(builder: (context, c) {
                    final cols = c.maxWidth >= 560 ? 4 : 2;
                    final w = (c.maxWidth - (cols - 1) * 12) / cols;
                    Widget tile(String label, int n, IconData icon, Color color, JobStatus? filter) => SizedBox(
                          width: w,
                          child: _StatTile(
                            label: label,
                            count: n,
                            icon: icon,
                            color: color,
                            onTap: () {
                              final f = ref.read(jobFilterProvider.notifier)..clear();
                              if (filter != null) f.toggleStatus(filter);
                              ref.read(tabIndexProvider.notifier).set(1);
                            },
                          ),
                        );
                    return Wrap(spacing: 12, runSpacing: 12, children: [
                      tile('Assigned', count(JobStatus.assigned), Icons.assignment_outlined, JobStatus.assigned.color, JobStatus.assigned),
                      tile('Pending', count(JobStatus.accepted), Icons.hourglass_bottom, JobStatus.accepted.color, JobStatus.accepted),
                      tile('In progress', count(JobStatus.inProgress), Icons.play_circle_outline, JobStatus.inProgress.color, JobStatus.inProgress),
                      tile('Completed', count(JobStatus.completed), Icons.check_circle_outline, JobStatus.completed.color, JobStatus.completed),
                    ]);
                  }),
                  if (closed > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('$closed more declined, cancelled or failed · see Activity',
                          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    ),
                  const SizedBox(height: 20),
                  Text('Needs your attention', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (important.isEmpty)
                    const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text("You're all caught up. No open jobs."))
                  else
                    for (final j in important) _gap(JobCard(job: j, hasPending: pendingIds.contains(j.id), onTap: () => openJob(context, j.id))),
                  const SizedBox(height: 12),
                  Text('Recently updated', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  for (final j in recent) _gap(JobCard(job: j, hasPending: pendingIds.contains(j.id), onTap: () => openJob(context, j.id))),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      sync.lastRefresh == null ? 'Not synced yet' : 'Last synced ${TimeOfDay.fromDateTime(sync.lastRefresh!).format(context)}',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.outline),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _gap(Widget w) => Padding(padding: const EdgeInsets.only(bottom: 10), child: w);

  void _accountSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final s = ref.read(authProvider).value;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(leading: const CircleAvatar(child: Icon(Icons.person)), title: Text(s?.name ?? ''), subtitle: Text(s?.email ?? '')),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _confirmSignOut(context, ref);
                },
              ),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final unsynced = (await ref.read(repositoryProvider).outbox()).length;
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: Text(unsynced > 0
            ? 'You have $unsynced change${unsynced == 1 ? '' : 's'} that have not synced yet. Signing out will discard ${unsynced == 1 ? 'it' : 'them'}. Connect to the internet and sync first to keep your work.'
            : 'Saved jobs on this device will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(unsynced > 0 ? 'Discard and sign out' : 'Sign out')),
        ],
      ),
    );
    if (ok == true) await ref.read(authProvider.notifier).logout();
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.count, required this.icon, required this.color, required this.onTap});
  final String label;
  final int count;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      button: true,
      label: '$label: $count jobs',
      excludeSemantics: true,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: color),
              const SizedBox(height: 8),
              Text('$count', style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}

void openJob(BuildContext context, String id) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => JobDetailScreen(jobId: id)));
