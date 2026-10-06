import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// V2 defense-in-depth (NEW_TASKS Production Hardening): role guards live in
/// EACH admin sub-screen, not only in the Admin hub that normally opens them,
/// so a direct push / deep link / future call site can never skip the gate.
///
/// Usage: `class _FooState extends State<Foo> with AdminGateMixin`, expose
/// `AuthService get auth => widget.auth;`, and start `build` with:
///
/// ```dart
/// if (!roleChecked) return const LoadingView();
/// if (!adminAllowed) return const AdminDeniedView();
/// ```
///
/// The server rules already reject non-admin writes; this only keeps PT Sir
/// out of the admin UI itself.
mixin AdminGateMixin<T extends StatefulWidget> on State<T> {
  AuthService get auth;

  bool? _isAdmin;

  /// Null until [checkAdminRole] has completed.
  bool get roleChecked => _isAdmin != null;

  /// True only once the role resolves to `admin`.
  bool get adminAllowed => _isAdmin == true;

  @override
  void initState() {
    super.initState();
    _checkAdminRole();
  }

  Future<void> _checkAdminRole() async {
    bool allowed;
    try {
      allowed = await auth.currentUserRole == 'admin';
    } catch (_) {
      // Deny-by-default: a failed role fetch must never leave the gate stuck
      // on the spinner (review finding MEDIUM) — no role, no admin UI.
      allowed = false;
    }
    if (!mounted) return;
    setState(() => _isAdmin = allowed);
  }
}

/// Spinner shown while the admin role check is still in flight.
class AdminGateLoading extends StatelessWidget {
  const AdminGateLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

/// Plain-language denial body, mirroring the Admin hub's "Admin access only."
/// screen (same copy the pinned tests expect there).
class AdminDeniedView extends StatelessWidget {
  const AdminDeniedView({super.key});

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline, size: 40, color: AppColors.statusEscalate),
              const SizedBox(height: 12),
              Text(
                'Admin access only.',
                style: GoogleFonts.inter(
                  color: AppColors.ink900,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Student master data can only be managed by an admin account.',
                style: GoogleFonts.inter(
                  color: AppColors.ink900.withValues(alpha: 0.7),
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              if (canPop) ...[
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
