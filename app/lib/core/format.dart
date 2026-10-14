import 'package:intl/intl.dart';

final _date = DateFormat('d MMM yyyy');
final _dateTime = DateFormat('d MMM, h:mm a');

String formatDate(DateTime d) => _date.format(d.toLocal());
String formatDateTime(DateTime d) => _dateTime.format(d.toLocal());

String formatBytes(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// "Due today", "Overdue by 2 days", "Due in 3 days"
String dueLabel(DateTime due, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final d = DateTime(due.toLocal().year, due.toLocal().month, due.toLocal().day);
  final t = DateTime(n.year, n.month, n.day);
  final diff = d.difference(t).inDays;
  if (diff == 0) return 'Due today';
  if (diff == 1) return 'Due tomorrow';
  if (diff > 1) return 'Due in $diff days';
  return diff == -1 ? 'Overdue by 1 day' : 'Overdue by ${-diff} days';
}
