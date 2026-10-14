import 'package:flutter/material.dart';

/// Mirrors the server state machine so the app can validate offline.
enum JobStatus {
  assigned('assigned', 'Assigned', Icons.assignment_outlined, Color(0xFF1565C0)),
  accepted('accepted', 'Accepted', Icons.thumb_up_alt_outlined, Color(0xFF3949AB)),
  inProgress('in_progress', 'In progress', Icons.play_circle_outline, Color(0xFFB26A00)),
  completed('completed', 'Completed', Icons.check_circle_outline, Color(0xFF2E7D32)),
  declined('declined', 'Declined', Icons.block, Color(0xFF616161)),
  cancelled('cancelled', 'Cancelled', Icons.cancel_outlined, Color(0xFF546E7A)),
  failed('failed', 'Failed', Icons.error_outline, Color(0xFFC62828));

  const JobStatus(this.wire, this.label, this.icon, this.color);
  final String wire;
  final String label;
  final IconData icon;
  final Color color;

  static JobStatus parse(String s) =>
      JobStatus.values.firstWhere((v) => v.wire == s, orElse: () => JobStatus.assigned);

  List<JobStatus> get next => switch (this) {
        assigned => [accepted, declined],
        accepted => [inProgress, cancelled],
        inProgress => [completed, failed],
        _ => const [],
      };

  bool get needsReason => this == declined || this == cancelled || this == failed;

  /// Notes, form answers and evidence can only change in these states.
  bool get isWorkable => this == accepted || this == inProgress;

  /// Still on the agent's plate (not terminal).
  bool get isOpen => this == assigned || this == accepted || this == inProgress;
}

enum JobPriority {
  low('low', 'Low', Color(0xFF546E7A)),
  medium('medium', 'Medium', Color(0xFF1565C0)),
  high('high', 'High', Color(0xFFB26A00)),
  urgent('urgent', 'Urgent', Color(0xFFC62828));

  const JobPriority(this.wire, this.label, this.color);
  final String wire;
  final String label;
  final Color color;

  static JobPriority parse(String s) =>
      JobPriority.values.firstWhere((v) => v.wire == s, orElse: () => JobPriority.medium);
}
