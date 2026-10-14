import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/job_status.dart';
import '../../domain/outbox.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../dashboard/dashboard_screen.dart' show openJob;

class JobsScreen extends ConsumerStatefulWidget {
  const JobsScreen({super.key});
  @override
  ConsumerState<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends ConsumerState<JobsScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(jobFilterProvider);
    final jobs = ref.watch(jobsProvider);
    final sync = ref.watch(syncProvider);
    final pendingIds = (ref.watch(outboxProvider).value ?? const <OutboxItem>[]).map((o) => o.jobId).toSet();
    // Keep the text field in step when the dashboard tiles reset the filter.
    if (filter.query != _search.text) _search.text = filter.query;

    return Scaffold(
      appBar: AppBar(title: const Text('Jobs')),
      body: ContentWidth(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: ref.read(jobFilterProvider.notifier).setQuery,
              decoration: InputDecoration(
                hintText: 'Search title, customer or location',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: filter.query.isEmpty
                    ? null
                    : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close), onPressed: () => ref.read(jobFilterProvider.notifier).setQuery('')),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final s in JobStatus.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(s.label),
                      selected: filter.statuses.contains(s),
                      onSelected: (_) => ref.read(jobFilterProvider.notifier).toggleStatus(s),
                    ),
                  ),
                PopupMenuButton<JobPriority?>(
                  tooltip: 'Filter by priority',
                  onSelected: ref.read(jobFilterProvider.notifier).setPriority,
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: null, child: Text('Any priority')),
                    for (final p in JobPriority.values) PopupMenuItem(value: p, child: Text(p.label)),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.flag_outlined, size: 18),
                    label: Text(filter.priority?.label ?? 'Priority'),
                    backgroundColor: filter.priority != null ? Theme.of(context).colorScheme.secondaryContainer : null,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: jobs.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => ErrorState(error: e, onRetry: () => ref.invalidate(jobsProvider)),
              data: (all) {
                if (all.isEmpty && !sync.loadedOnce) {
                  return sync.error != null
                      ? ErrorState(error: sync.error!, onRetry: () => ref.read(syncProvider.notifier).pull())
                      : const Center(child: CircularProgressIndicator());
                }
                final list = all.where(filter.matches).toList()..sort(compareJobs);
                Widget body;
                if (all.isEmpty) {
                  body = const EmptyState(icon: Icons.inbox_outlined, title: 'No jobs assigned yet', message: 'New assignments will appear here.');
                } else if (list.isEmpty) {
                  body = EmptyState(
                    icon: Icons.search_off,
                    title: 'No matching jobs',
                    message: 'Try a different search or clear the filters.',
                    action: OutlinedButton(onPressed: ref.read(jobFilterProvider.notifier).clear, child: const Text('Clear filters')),
                  );
                } else {
                  body = ListView.separated(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => JobCard(job: list[i], hasPending: pendingIds.contains(list[i].id), onTap: () => openJob(context, list[i].id)),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () => ref.read(syncProvider.notifier).pull(),
                  // Empty states need a scrollable child for pull-to-refresh to work.
                  child: list.isEmpty ? LayoutBuilder(builder: (_, c) => ListView(children: [SizedBox(height: c.maxHeight, child: body)])) : body,
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
