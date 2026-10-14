import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_exception.dart';
import '../domain/outbox.dart';
import '../state/providers.dart';

/// One strip that explains connectivity + sync state: offline, syncing, N waiting, N need attention.
class SyncBanner extends ConsumerWidget {
  const SyncBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(onlineProvider).value ?? true;
    final sync = ref.watch(syncProvider);
    final outbox = ref.watch(outboxProvider).value ?? const <OutboxItem>[];
    final waiting = outbox.where((o) => o.state != OutboxState.failed).length;
    final failed = outbox.where((o) => o.state == OutboxState.failed).length;
    final t = Theme.of(context);

    String? text;
    IconData icon = Icons.cloud_off;
    Color bg = t.colorScheme.surfaceContainerHighest;
    Color fg = t.colorScheme.onSurface;
    if (failed > 0) {
      text = '$failed change${failed == 1 ? '' : 's'} could not be saved. Open the job to retry or discard.';
      icon = Icons.error_outline;
      bg = t.colorScheme.errorContainer;
      fg = t.colorScheme.onErrorContainer;
    } else if (!online) {
      text = waiting > 0 ? "You're offline. $waiting change${waiting == 1 ? '' : 's'} will sync when you're back online." : "You're offline. Showing saved data.";
    } else if (sync.busy && waiting > 0) {
      text = 'Syncing $waiting change${waiting == 1 ? '' : 's'}…';
      icon = Icons.sync;
    } else if (waiting > 0 || (sync.error != null && sync.error!.kind != ErrorKind.sessionExpired)) {
      text = waiting > 0 ? '$waiting change${waiting == 1 ? '' : 's'} waiting to sync. ${sync.error?.message ?? ''}'.trim() : sync.error!.message;
      icon = Icons.cloud_upload_outlined;
    }
    if (text == null) return const SizedBox.shrink();

    return Semantics(
      liveRegion: true,
      child: Material(
        color: bg,
        child: InkWell(
          onTap: online ? () => ref.read(syncProvider.notifier).pull() : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: TextStyle(color: fg, fontSize: 13))),
              if (online && failed == 0 && !sync.busy) Text('Sync now', style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13)),
            ]),
          ),
        ),
      ),
    );
  }
}
