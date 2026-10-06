import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../theme/app_theme.dart';

/// Searchable HOD picker (docs-new-updates/NEW_TASKS.md Phase 2 "HOD search").
/// Lists the departments reference docs with their HOD email; the query narrows
/// by department name, id or email. Departments without a HOD email on file
/// cannot receive a report mail and are shown disabled.
///
/// Returns the chosen [DepartmentInfo] via Navigator.pop, or null if dismissed.
class HodPickerScreen extends StatefulWidget {
  const HodPickerScreen({
    super.key,
    required this.departments,
    this.selectedId,
  });

  final List<DepartmentInfo> departments;
  final String? selectedId;

  @override
  State<HodPickerScreen> createState() => _HodPickerScreenState();
}

class _HodPickerScreenState extends State<HodPickerScreen> {
  String _query = '';
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.selectedId;
  }

  List<DepartmentInfo> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.departments;
    return widget.departments.where((d) {
      return displayToken(d.name).contains(displayToken(q)) ||
          displayToken(d.id).contains(displayToken(q)) ||
          (d.hodEmail ?? '').toLowerCase().contains(q);
    }).toList();
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
          'Send to HOD',
          style: GoogleFonts.inter(
            color: AppColors.navy900,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: TextField(
                key: const ValueKey('hod-search'),
                autofocus: false,
                maxLength: 64,
                decoration: const InputDecoration(
                  hintText: 'Search by department or HOD email',
                  prefixIcon: Icon(Icons.search, size: 20),
                  counterText: '',
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: _filtered.isEmpty
                  ? _emptyState()
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _filtered.length,
                      separatorBuilder: (_, _) => const Divider(
                        color: AppColors.sand200,
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                      ),
                      itemBuilder: (context, index) =>
                          _deptTile(_filtered[index]),
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _selectedId == null
                ? null
                : () {
                    for (final d in widget.departments) {
                      if (d.id == _selectedId) {
                        Navigator.of(context).pop(d);
                        return;
                      }
                    }
                  },
            child: const Text('Confirm HOD'),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No departments match \u2018$_query\u2019.',
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            color: AppColors.ink900.withValues(alpha: 0.7),
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _deptTile(DepartmentInfo dept) {
    final hasEmail = (dept.hodEmail ?? '').trim().isNotEmpty;
    final selected = dept.id == _selectedId;
    return ListTile(
      enabled: hasEmail,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 20,
        color: hasEmail
            ? (selected ? AppColors.maroon700 : AppColors.ink900.withValues(alpha: 0.4))
            : AppColors.ink900.withValues(alpha: 0.2),
      ),
      title: Text(
        dept.name,
        style: GoogleFonts.inter(
          color: hasEmail ? AppColors.ink900 : AppColors.ink900.withValues(alpha: 0.4),
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        hasEmail ? dept.hodEmail! : 'No HOD email on file',
        style: GoogleFonts.inter(
          color: hasEmail
              ? AppColors.ink900.withValues(alpha: 0.6)
              : AppColors.ink900.withValues(alpha: 0.35),
          fontSize: 13,
        ),
      ),
      selected: selected,
      onTap: hasEmail
          ? () => setState(() => _selectedId = dept.id)
          : null,
    );
  }
}