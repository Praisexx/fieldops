import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_exception.dart';
import '../core/config.dart';
import '../data/api_client.dart';
import '../data/evidence_files.dart';
import '../data/job_repository.dart';
import '../data/local_db.dart';
import '../data/token_storage.dart';
import '../domain/job_status.dart';
import '../domain/models.dart';
import '../domain/outbox.dart';

// ---- infrastructure (db / files dir are opened in main() and injected) ----
final localDbProvider = Provider<LocalDb>((_) => throw UnimplementedError('override in main'));
final filesDirProvider = Provider<Directory>((_) => throw UnimplementedError('override in main'));
final tokenStorageProvider = Provider<TokenStorage>((_) => SecureTokenStorage());

/// Bumped whenever local data changes; read-providers watch it and reload from SQLite.
class RevisionNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final revisionProvider = NotifierProvider<RevisionNotifier, int>(RevisionNotifier.new);

/// clientId -> upload progress (0..1) for evidence currently uploading.
class ProgressNotifier extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => const {};
  void set(String clientId, double? v) {
    final next = {...state};
    v == null ? next.remove(clientId) : next[clientId] = v;
    state = next;
  }
}

final uploadProgressProvider = NotifierProvider<ProgressNotifier, Map<String, double>>(ProgressNotifier.new);

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(
      baseUrl: apiBaseUrl,
      tokens: ref.watch(tokenStorageProvider),
      onSessionExpired: () => ref.read(authProvider.notifier).sessionExpired(),
    ));

final repositoryProvider = Provider<JobRepository>((ref) => JobRepository(
      api: ref.watch(apiClientProvider),
      db: ref.watch(localDbProvider),
      filesDir: ref.watch(filesDirProvider),
      onChanged: () => ref.read(revisionProvider.notifier).bump(),
      onProgress: (id, v) => ref.read(uploadProgressProvider.notifier).set(id, v),
    ));

final evidenceFilesProvider = Provider<EvidenceFiles>(
    (ref) => EvidenceFiles(api: ref.watch(apiClientProvider), dir: ref.watch(filesDirProvider)));

// ---- auth ----
class AuthNotice extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? v) => state = v;
}

final authNoticeProvider = NotifierProvider<AuthNotice, String?>(AuthNotice.new);

class AuthController extends AsyncNotifier<Session?> {
  @override
  Future<Session?> build() => ref.read(tokenStorageProvider).read();

  Future<void> login(String email, String password) async {
    final s = await ref.read(apiClientProvider).login(email, password);
    final db = ref.read(localDbProvider);
    final previous = await db.meta('userId');
    // A different agent must never see the previous agent's cached jobs.
    if (previous != null && previous != s.userId) await ref.read(repositoryProvider).clearAll();
    await db.setMeta('userId', s.userId);
    await ref.read(tokenStorageProvider).write(s);
    ref.read(authNoticeProvider.notifier).set(null);
    state = AsyncData(s);
  }

  Future<void> logout() async {
    final s = state.value;
    if (s != null) unawaited(ref.read(apiClientProvider).logout(s.refreshToken));
    await ref.read(tokenStorageProvider).clear();
    await ref.read(repositoryProvider).clearAll();
    ref.read(authNoticeProvider.notifier).set(null);
    state = const AsyncData(null);
  }

  /// Refresh token rejected: drop tokens but KEEP cached data and queued actions so nothing is lost;
  /// they sync after the same agent signs in again.
  void sessionExpired() {
    if (state.value == null) return;
    ref.read(authNoticeProvider.notifier).set('Your session expired. Sign in again to continue; your offline work is safe and will sync.');
    state = const AsyncData(null);
  }
}

final authProvider = AsyncNotifierProvider<AuthController, Session?>(AuthController.new);

class TabIndex extends Notifier<int> {
  @override
  int build() => 0;
  void set(int i) => state = i;
}

final tabIndexProvider = NotifierProvider<TabIndex, int>(TabIndex.new);

// ---- connectivity / sync ----
bool _isOnline(List<ConnectivityResult> r) => r.any((x) => x != ConnectivityResult.none);

final onlineProvider = StreamProvider<bool>((ref) async* {
  final c = Connectivity();
  yield _isOnline(await c.checkConnectivity());
  yield* c.onConnectivityChanged.map(_isOnline);
});

class SyncStatus {
  const SyncStatus({this.busy = false, this.error, this.lastRefresh, this.loadedOnce = false});
  final bool busy;
  final AppException? error;
  final DateTime? lastRefresh;
  final bool loadedOnce;
  SyncStatus copyWith({bool? busy, AppException? error, bool clearError = false, DateTime? lastRefresh, bool? loadedOnce}) => SyncStatus(
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
        lastRefresh: lastRefresh ?? this.lastRefresh,
        loadedOnce: loadedOnce ?? this.loadedOnce,
      );
}

/// Runs while signed in: pushes queued actions, then pulls fresh data. Triggers: app start, pull-to-refresh,
/// connectivity returning, and a timer while anything is still queued.
class SyncController extends Notifier<SyncStatus> {
  Timer? _timer;

  @override
  SyncStatus build() {
    ref.listen<AsyncValue<bool>>(onlineProvider, (prev, next) {
      if (next.value == true && prev?.value == false) unawaited(pull());
    });
    _timer = Timer.periodic(const Duration(seconds: 45), (_) async {
      if ((await ref.read(repositoryProvider).outbox()).any((o) => o.state == OutboxState.pending)) unawaited(pull());
    });
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(() async {
      final last = await ref.read(repositoryProvider).lastRefresh();
      state = state.copyWith(lastRefresh: last, loadedOnce: last != null);
      await pull();
    });
    return const SyncStatus();
  }

  Future<void> pull() async {
    if (state.busy) return;
    state = state.copyWith(busy: true);
    final repo = ref.read(repositoryProvider);
    try {
      final flush = await repo.sync.flush();
      if (flush.error != null) throw flush.error!;
      await repo.refreshAll();
      state = state.copyWith(busy: false, clearError: true, lastRefresh: DateTime.now(), loadedOnce: true);
    } catch (e) {
      state = state.copyWith(busy: false, error: AppException.from(e));
    }
  }
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);

// ---- data ----
final jobsProvider = FutureProvider<List<Job>>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(repositoryProvider).jobs();
});

final jobProvider = FutureProvider.family<Job?, String>((ref, id) {
  ref.watch(revisionProvider);
  return ref.watch(repositoryProvider).job(id);
});

final outboxProvider = FutureProvider<List<OutboxItem>>((ref) {
  ref.watch(revisionProvider);
  return ref.watch(repositoryProvider).outbox();
});

// ---- filters (applied locally so search works offline) ----
class JobFilter {
  const JobFilter({this.query = '', this.statuses = const {}, this.priority});
  final String query;
  final Set<JobStatus> statuses;
  final JobPriority? priority;

  bool get isActive => query.isNotEmpty || statuses.isNotEmpty || priority != null;

  bool matches(Job j) {
    if (statuses.isNotEmpty && !statuses.contains(j.status)) return false;
    if (priority != null && j.priority != priority) return false;
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [j.title, j.customerName, j.location, j.description, j.type].any((s) => s.toLowerCase().contains(q));
  }
}

class JobFilterNotifier extends Notifier<JobFilter> {
  @override
  JobFilter build() => const JobFilter();
  void setQuery(String q) => state = JobFilter(query: q, statuses: state.statuses, priority: state.priority);
  void toggleStatus(JobStatus s) {
    final next = {...state.statuses};
    next.contains(s) ? next.remove(s) : next.add(s);
    state = JobFilter(query: state.query, statuses: next, priority: state.priority);
  }

  void setPriority(JobPriority? p) => state = JobFilter(query: state.query, statuses: state.statuses, priority: p);
  void clear() => state = const JobFilter();
}

final jobFilterProvider = NotifierProvider<JobFilterNotifier, JobFilter>(JobFilterNotifier.new);

/// Open jobs first (urgent → low, then soonest due), closed jobs last.
int compareJobs(Job a, Job b) {
  if (a.status.isOpen != b.status.isOpen) return a.status.isOpen ? -1 : 1;
  if (a.status.isOpen) {
    final p = b.priority.index.compareTo(a.priority.index);
    if (p != 0) return p;
    final ad = a.dueDate, bd = b.dueDate;
    if (ad != null && bd != null) return ad.compareTo(bd);
    if (ad != null) return -1;
    if (bd != null) return 1;
  }
  return b.updatedAt.compareTo(a.updatedAt);
}
