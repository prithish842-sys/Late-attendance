import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import '../theme/app_theme.dart';
import 'batch_import_screen.dart';
import 'pass_out_review_screen.dart';
import 'recently_deleted_screen.dart';
import 'student_management_screen.dart';

const _adminRole = 'admin';

/// Phase 4 Admin hub (docs-new-updates/NEW_TASKS.md Phase 4, NEW_SECURITY.md):
/// the only entry point behind which a staff member can touch the student
/// master data. Role-gated here AND server-side: no admin_requests are
/// accepted from pt_sir, and the Blaze callables all require admin.
class AdminScreen extends StatefulWidget {
  const AdminScreen({
    super.key,
    required this.auth,
    required this.firestore,
    required this.userId,
  });

  final AuthService auth;
  final FirestoreService firestore;
  final String userId;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  bool? _isAdmin;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  Future<void> _loadRole() async {
    final role = await widget.auth.currentUserRole;
    if (!mounted) return;
    setState(() {
      _isAdmin = role == _adminRole;
      _denied = !(_isAdmin ?? false);
    });
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Admin',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: _denied ? _buildDenied() : _buildHub(),
    );
  }

  Widget _buildDenied() {
    return Center(
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
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHub() {
    if (_isAdmin == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        Text(
          'Student master data',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Imports and lifecycle changes are server-verified and audited '
          '(NEW_ADMIN_WORKFLOW.md).',
          style: GoogleFonts.inter(
            color: AppColors.ink900.withValues(alpha: 0.6),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 14),
        _tile(
          icon: Icons.people_outline,
          title: 'Student management',
          subtitle: 'Search, filter by batch, and archive students',
          onTap: () => _open(StudentManagementScreen(
            auth: widget.auth,
            firestore: widget.firestore,
            userId: widget.userId,
          )),
        ),
        _tile(
          icon: Icons.upload_file_outlined,
          title: 'Batch import',
          subtitle: 'Upload an Excel roster, preview, then commit',
          onTap: () => _open(BatchImportScreen(
            auth: widget.auth,
            firestore: widget.firestore,
            userId: widget.userId,
          )),
        ),
        _tile(
          icon: Icons.school_outlined,
          title: 'Pass-out review',
          subtitle: 'Review batches that have finished and archive them',
          onTap: () => _open(PassOutReviewScreen(
            auth: widget.auth,
            firestore: widget.firestore,
            userId: widget.userId,
          )),
        ),
        _tile(
          icon: Icons.restore_from_trash_outlined,
          title: 'Recently deleted',
          subtitle: 'Restore a soft-deleted student, or purge permanently',
          onTap: () => _open(RecentlyDeletedScreen(
            auth: widget.auth,
            firestore: widget.firestore,
            userId: widget.userId,
          )),
        ),
      ],
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.sand200),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(icon, size: 26, color: AppColors.maroon900),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: GoogleFonts.inter(
                          color: AppColors.ink900,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: GoogleFonts.inter(
                          color: AppColors.ink900.withValues(alpha: 0.6),
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.maroon900),
              ],
            ),
          ),
        ),
      ),
    );
  }
}