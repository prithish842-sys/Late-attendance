import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../theme/app_theme.dart';

/// Late-count severity, DESIGN.md §1. Color is never the only signal — every
/// badge carries the explicit count text alongside the color.
enum LateSeverity { ok, warn, escalate }

LateSeverity severityFor(int count, ScanSettings settings) {
  final threshold = settings.escalationThreshold <= 0 ? 3 : settings.escalationThreshold;
  if (count >= threshold) return LateSeverity.escalate;
  if (count >= 2) return LateSeverity.warn;
  return LateSeverity.ok;
}

Color severityColor(LateSeverity s) {
  switch (s) {
    case LateSeverity.ok:
      return AppColors.statusOk;
    case LateSeverity.warn:
      return AppColors.statusWarn;
    case LateSeverity.escalate:
      return AppColors.statusEscalate;
  }
}

/// "1st", "2nd", "3rd", "4th", ... — used in badge copy.
String ordinal(int n) {
  final mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 13) return '${n}th';
  switch (n % 10) {
    case 1:
      return '${n}st';
    case 2:
      return '${n}nd';
    case 3:
      return '${n}rd';
    default:
      return '${n}th';
  }
}

/// The color-coded late-count badge. Always pairs color with explicit text
/// ("2nd time this month"), per DESIGN.md §6.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.count, required this.settings})
      : _verdict = null;

  /// Rendered from the server-authoritative escalation_queue verdict
  /// (SECURITY.md §1). Never renders client-computed state when present.
  StatusBadge.fromVerdict(EscalationVerdict verdict, {super.key, required this.settings})
      : count = verdict.count,
        _verdict = verdict;

  final int count;
  final ScanSettings settings;
  final EscalationVerdict? _verdict;

  @override
  Widget build(BuildContext context) {
    // Server verdict wins — its status is authoritative regardless of what
    // the local count would suggest.
    final severity = switch (_verdict?.status) {
      'escalated' => LateSeverity.escalate,
      'warning' => LateSeverity.warn,
      _ => severityFor(count, settings),
    };
    final color = severityColor(severity);
    final copy = _verdict?.isEscalated == true
        ? 'Escalated \u2014 threshold reached'
        : _verdict?.isWarning == true
            ? '${ordinal(count)} time \u2014 warning'
            : '${ordinal(count)} time this month';
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            copy,
            style: GoogleFonts.inter(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}