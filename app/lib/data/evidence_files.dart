import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/models.dart';
import 'api_client.dart';

/// Resolves an evidence item to a local file: the original capture if we made it on this device,
/// otherwise a download cached on first view (so it also opens offline afterwards).
class EvidenceFiles {
  EvidenceFiles({required this.api, required this.dir});
  final ApiClient api;
  final Directory dir;

  Future<File> resolve(String jobId, Evidence e) async {
    if (e.clientId != null) {
      final own = File(p.join(dir.path, 'evidence', e.clientId!));
      if (own.existsSync()) return own;
    }
    final cached = File(p.join(dir.path, 'evidence_cache', e.id));
    if (cached.existsSync()) return cached;
    final bytes = await api.downloadEvidence(jobId, e.id);
    await cached.parent.create(recursive: true);
    return cached.writeAsBytes(bytes);
  }
}
