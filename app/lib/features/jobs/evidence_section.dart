import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/app_exception.dart';
import '../../core/format.dart';
import '../../domain/models.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import 'job_detail_screen.dart' show askText;

String _mimeFor(String path) {
  final ext = path.split('.').last.toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'doc' => 'application/msword',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    _ => 'application/octet-stream',
  };
}

class EvidenceSection extends ConsumerWidget {
  const EvidenceSection({super.key, required this.job, this.problem});
  final Job job;
  final String? problem;

  Future<void> _guard(BuildContext context, Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (context.mounted) showSnack(context, AppException.from(e).message, error: true);
    }
  }

  Future<void> _photo(BuildContext context, WidgetRef ref, ImageSource source) => _guard(context, () async {
        final x = await ImagePicker().pickImage(source: source, maxWidth: 2048, imageQuality: 80);
        if (x == null) return;
        await ref.read(repositoryProvider).addFileEvidence(job,
            kind: EvidenceKind.photo, sourcePath: x.path, filename: x.name, mime: _mimeFor(x.path));
      });

  Future<void> _document(BuildContext context, WidgetRef ref) => _guard(context, () async {
        final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'txt', 'doc', 'docx', 'xls', 'xlsx']);
        final f = r.isEmpty ? null : r.first;
        if (f == null || f.path == null) return;
        await ref.read(repositoryProvider).addFileEvidence(job,
            kind: EvidenceKind.document, sourcePath: f.path!, filename: f.name, mime: _mimeFor(f.name));
      });

  Future<void> _text(BuildContext context, WidgetRef ref) async {
    final text = await askText(context, title: 'Add text evidence', label: 'Details', confirm: 'Add', required: true, maxLength: 4000);
    if (text == null || !context.mounted) return;
    await _guard(context, () => ref.read(repositoryProvider).addTextEvidence(job, text));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canEdit = job.status.isWorkable;
    final need = job.evidenceRequired;
    return SectionCard(
      title: 'Evidence',
      trailing: need > 0
          ? Text('${job.evidence.length}/$need required', style: t.textTheme.labelMedium?.copyWith(color: job.evidence.length >= need ? Colors.green.shade700 : t.colorScheme.onSurfaceVariant))
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (problem != null)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(problem!, style: TextStyle(color: t.colorScheme.error))),
        if (job.evidence.isEmpty)
          Text(
            canEdit ? 'No evidence yet. Add photos, documents or a text note.' : (job.hasDetail ? 'No evidence submitted.' : 'Connect to the internet to load evidence.'),
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        for (final e in job.evidence) _EvidenceTile(job: job, e: e, canDelete: canEdit),
        if (canEdit) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: () => _photo(context, ref, ImageSource.camera), icon: const Icon(Icons.photo_camera_outlined), label: const Text('Camera')),
            OutlinedButton.icon(onPressed: () => _photo(context, ref, ImageSource.gallery), icon: const Icon(Icons.photo_library_outlined), label: const Text('Gallery')),
            OutlinedButton.icon(onPressed: () => _document(context, ref), icon: const Icon(Icons.description_outlined), label: const Text('Document')),
            OutlinedButton.icon(onPressed: () => _text(context, ref), icon: const Icon(Icons.notes), label: const Text('Text')),
          ]),
        ],
      ]),
    );
  }
}

class _EvidenceTile extends ConsumerWidget {
  const _EvidenceTile({required this.job, required this.e, required this.canDelete});
  final Job job;
  final Evidence e;
  final bool canDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final progress = e.clientId == null ? null : ref.watch(uploadProgressProvider)[e.clientId];
    final (label, color) = switch (e.sync) {
      SyncState.synced => ('Uploaded', Colors.green.shade700),
      SyncState.syncing => (progress == null ? 'Uploading…' : 'Uploading ${(progress * 100).round()}%', t.colorScheme.primary),
      SyncState.pending => ('Waiting to upload', t.colorScheme.outline),
      SyncState.failed => ('Upload failed', t.colorScheme.error),
    };
    final title = e.kind == EvidenceKind.text ? (e.text ?? '') : (e.filename ?? 'File');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _open(context, ref),
          child: SizedBox(width: 56, height: 56, child: _Thumb(job: job, e: e)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text([switch (e.kind) { EvidenceKind.photo => 'Photo', EvidenceKind.document => 'Document', EvidenceKind.text => 'Text note' }, if (e.size != null) formatBytes(e.size)].join(' · '),
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            Row(children: [
              if (e.sync == SyncState.syncing) const Padding(padding: EdgeInsets.only(right: 6), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))),
              Flexible(child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600))),
            ]),
            if (e.sync == SyncState.syncing && progress != null) Padding(padding: const EdgeInsets.only(top: 4), child: LinearProgressIndicator(value: progress)),
          ]),
        ),
        if (canDelete)
          IconButton(
            tooltip: 'Remove evidence',
            icon: const Icon(Icons.delete_outline),
            onPressed: e.sync == SyncState.syncing ? null : () => _delete(context, ref),
          ),
      ]),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this evidence?'),
        content: const Text('It will be removed from the job.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(repositoryProvider).deleteEvidence(job, e);
    } catch (err) {
      if (context.mounted) showSnack(context, AppException.from(err).message, error: true);
    }
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    if (e.kind == EvidenceKind.text) {
      await showDialog<void>(context: context, builder: (ctx) => AlertDialog(title: const Text('Text evidence'), content: SingleChildScrollView(child: Text(e.text ?? '')), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))]));
      return;
    }
    if (e.kind == EvidenceKind.document) {
      showSnack(context, 'Documents are stored securely with the job. Previewing is not supported yet.');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _PhotoViewer(job: job, e: e)));
  }
}

class _Thumb extends ConsumerWidget {
  const _Thumb({required this.job, required this.e});
  final Job job;
  final Evidence e;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    Widget box(IconData i) => Container(
          decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
          child: Icon(i, color: t.colorScheme.onSurfaceVariant),
        );
    if (e.kind == EvidenceKind.text) return box(Icons.notes);
    if (e.kind == EvidenceKind.document) return box(Icons.description_outlined);
    return FutureBuilder<File>(
      future: ref.read(evidenceFilesProvider).resolve(job.id, e),
      builder: (_, snap) {
        if (snap.hasData) {
          return ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(snap.data!, fit: BoxFit.cover, cacheWidth: 200, errorBuilder: (_, _, _) => box(Icons.broken_image_outlined)));
        }
        return box(snap.hasError ? Icons.cloud_off_outlined : Icons.image_outlined);
      },
    );
  }
}

class _PhotoViewer extends ConsumerWidget {
  const _PhotoViewer({required this.job, required this.e});
  final Job job;
  final Evidence e;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(e.filename ?? 'Photo')),
        body: FutureBuilder<File>(
          future: ref.read(evidenceFilesProvider).resolve(job.id, e),
          builder: (_, snap) {
            if (snap.hasError) {
              return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(AppException.from(snap.error!).kind == ErrorKind.network ? 'Connect to the internet to load this photo.' : AppException.from(snap.error!).message, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center)));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return InteractiveViewer(child: Center(child: Image.file(snap.data!)));
          },
        ),
      );
}

class NotesSection extends ConsumerWidget {
  const NotesSection({super.key, required this.job});
  final Job job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final canEdit = job.status.isWorkable;
    final notes = job.notes.reversed.toList();
    return SectionCard(
      title: 'Notes',
      trailing: canEdit
          ? TextButton.icon(
              onPressed: () async {
                final body = await askText(context, title: 'Add note', label: 'Note', confirm: 'Add', required: true, maxLength: 2000);
                if (body == null || !context.mounted) return;
                try {
                  await ref.read(repositoryProvider).addNote(job, body);
                } catch (err) {
                  if (context.mounted) showSnack(context, AppException.from(err).message, error: true);
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Add note'),
            )
          : null,
      child: notes.isEmpty
          ? Text(canEdit ? 'No notes yet.' : (job.hasDetail ? 'No notes.' : 'Connect to the internet to load notes.'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))
          : Column(children: [
              for (final n in notes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(n.body),
                  subtitle: Text('${formatDateTime(n.createdAt)}${switch (n.sync) { SyncState.synced => '', SyncState.failed => ' · not saved', _ => ' · waiting to sync' }}'),
                ),
            ]),
    );
  }
}
