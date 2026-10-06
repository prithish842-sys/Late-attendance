import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Von Restorff treatment for an escalated (>= threshold of month lates) row
/// (docs-new-updates/NEW_DESIGN_PRINCIPLES.md): a soft maroon wash plus a thick
/// left rule so the row reads as a different object — not just a differently
/// colored badge. The explicit count text always stays alongside the wash;
/// color is never the only signal (DESIGN.md §5).
class EscalatedRule extends StatelessWidget {
  const EscalatedRule({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.statusEscalate.withValues(alpha: 0.06),
        border: const Border(
          left: BorderSide(color: AppColors.statusEscalate, width: 3),
        ),
      ),
      child: child,
    );
  }
}