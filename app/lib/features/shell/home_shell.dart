import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../widgets/sync_banner.dart';
import '../activity/activity_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../jobs/jobs_screen.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});
  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  @override
  Widget build(BuildContext context) {
    final index = ref.watch(tabIndexProvider);
    ref.watch(syncProvider); // starts background sync while signed in
    const pages = [DashboardScreen(), JobsScreen(), ActivityScreen()];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const SyncBanner(),
          Expanded(child: IndexedStack(index: index, children: pages)),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => ref.read(tabIndexProvider.notifier).set(i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.work_outline), selectedIcon: Icon(Icons.work), label: 'Jobs'),
          NavigationDestination(icon: Icon(Icons.history), label: 'Activity'),
        ],
      ),
    );
  }
}
