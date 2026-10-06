import 'package:excel/excel.dart';

import '../models/app_models.dart';

/// Client-side Excel import parsing + validation for the Batch Import screen
/// (docs-new-updates/NEW_TASKS.md Phase 4, NEW_ADMIN_WORKFLOW.md).
///
/// The validation rules HERE intentionally mirror functions/admin-core.js
/// validateImportRows EXACTLY (same wording, same order), so the preview the
/// admin approves is the same verdict the server enforces when the intent is
/// committed — departments and the current roster are re-checked server-side
/// and rows with errors are skipped there, never half-written.
///
/// Only [validateImportRows] is pure/unit-testable; [readSheetFile] needs the
/// `excel` package, so tests always exercise validation on [ImportRow] lists.

const _yearMin = 1990;
const _yearMax = 2100;
const _maxImportRows = 500;

int? parseYearInt(Object? value) {
  if (value is int) return value;
  if (value == null || value == '') return null;
  final text = value.toString().trim().replaceAll(RegExp(r'\.0+$'), '');
  final n = int.tryParse(text);
  return n;
}

String _yearOrdinal(int? currentYear) {
  switch (currentYear) {
    case 1:
      return '1st Year';
    case 2:
      return '2nd Year';
    case 3:
      return '3rd Year';
    case 4:
      return '4th Year';
    default:
      return 'Other';
  }
}

/// Display year label used for imported students (mirrors server yearLabel).
String importYearLabel(int? currentYear) => _yearOrdinal(currentYear);

/// Validated rows for the preview, mirroring the server's validateImportRows.
ImportSheetResult validateImportRows(
  List<ImportRow> rows, {
  List<DepartmentInfo> departments = const [],
  List<String> existingStudentIds = const [],
}) {
  final limited = rows.length > _maxImportRows ? rows.take(_maxImportRows).toList() : rows;
  final seen = <String>{};
  final results = <ImportRowResult>[];

  for (final row in limited) {
    final registerNumber = row.registerNumber.trim().toUpperCase();
    final name = row.name.trim();
    final department = row.department.trim();
    final batchStartYear = parseYearInt(row.batchStartYear);
    final batchEndYear = parseYearInt(row.batchEndYear);

    final errors = <String>[];
    final warnings = <String>[];

    if (registerNumber.isEmpty) errors.add('Register number is required.');
    if (registerNumber.length > 24) {
      errors.add('Register number must be 24 characters or fewer.');
    }
    if (seen.contains(registerNumber)) {
      errors.add('Duplicate register number in sheet ($registerNumber).');
    }
    seen.add(registerNumber);
    if (registerNumber.isNotEmpty && existingStudentIds.contains(registerNumber)) {
      errors.add('Register number $registerNumber is already on file.');
    }

    if (name.isEmpty) errors.add('Student name is required.');

    final dept = department.isNotEmpty ? findDepartment(departments, department) : null;
    if (department.isEmpty) {
      errors.add('Department is required.');
    } else if (dept == null) {
      errors.add('Department "$department" is not on file — add it in Admin › Departments first.');
    }

    final currentYear = parseYearInt(row.currentYear);
    if (currentYear == null) {
      errors.add('Current year must be a whole number.');
    } else if (currentYear < 1) {
      errors.add('Current year must be a positive whole number.');
    }

    if (batchStartYear == null) {
      errors.add('Batch start year must be a whole number.');
    } else if (batchStartYear < _yearMin || batchStartYear > _yearMax) {
      errors.add('Batch start year out of range ($_yearMin–$_yearMax).');
    }

    if (batchEndYear == null) {
      errors.add('Batch end year must be a whole number.');
    } else if (batchEndYear < _yearMin || batchEndYear > _yearMax) {
      errors.add('Batch end year out of range ($_yearMin–$_yearMax).');
    } else if (batchStartYear != null && batchEndYear < batchStartYear) {
      errors.add('Batch end year cannot be before the start year.');
    }

    if (currentYear != null &&
        batchStartYear != null &&
        batchEndYear != null &&
        batchEndYear >= batchStartYear) {
      final span = batchEndYear - batchStartYear + 1;
      if (currentYear < 1 || currentYear > span) {
        warnings.add(
            'Current year $currentYear is outside the batch $batchStartYear–$batchEndYear (expected 1–$span).');
      }
    }

    final prefixMatch = RegExp(r'^(\d{2})').firstMatch(registerNumber);
    if (prefixMatch != null && batchStartYear != null) {
      final prefixYear = 2000 + int.parse(prefixMatch.group(1)!);
      if (prefixYear != batchStartYear) {
        warnings.add('Register "$registerNumber" starts with the $prefixYear intake but the batch start year is $batchStartYear.');
      }
    }

    results.add(ImportRowResult(
      row: row,
      departmentId: dept?.id,
      departmentName: dept?.name,
      errors: errors,
      warnings: warnings,
      valid: errors.isEmpty && registerNumber.isNotEmpty && name.isNotEmpty,
    ));
  }

  final counts = ImportCounts(
    rows: results.length,
    valid: results.where((r) => r.valid).length,
    invalid: results.where((r) => !r.valid).length,
    warnings: results.fold<int>(0, (n, r) => n + r.warnings.length),
  );
  return ImportSheetResult(rows: results, counts: counts);
}

String? _cellText(Data? cell) {
  if (cell?.value == null) return null;
  final text = cell!.value.toString().trim();
  return text.isEmpty ? null : text;
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Decode an `.xlsx` byte array into raw [ImportRow]s, locating columns by
/// header tokens so the canonical NEW_ADMIN_WORKFLOW.md column order is the
/// default but not a hard requirement. Returns an empty list for an unreadable
/// file (the screen shows a plain-language pickup message).
List<ImportRow> readSheetRows(List<int> bytes) {
  final Excel excel;
  try {
    excel = Excel.decodeBytes(bytes);
  } catch (_) {
    return const [];
  }
  for (final table in excel.tables.values) {
    final rows = table.rows;
    if (rows.length < 2) continue;

    final header = rows.first.map((c) => _norm(_cellText(c) ?? '')).toList();
    int indexOf(List<String> tokens) => header.indexWhere((h) => tokens.any(h.contains));

    final iReg = indexOf(['registernumber', 'register', 'studentid']);
    final iName = indexOf(['studentname', 'name']);
    final iDept = indexOf(['department', 'dept']);
    final iCurr = indexOf(['currentyear', 'year']);
    final iStart = indexOf(['batchstartyear', 'batchstart', 'startyear']);
    final iEnd = indexOf(['batchendyear', 'batchend', 'endyear']);
    final iPhoto = indexOf(['photourl', 'photo', 'url']);

    if (iReg < 0 || iName < 0 || iDept < 0) {
      return const <ImportRow>[];
    }

    final out = <ImportRow>[];
    for (final line in rows.skip(1)) {
      final text = List<String?>.generate(line.length, (i) => _cellText(line[i]), growable: false);
      String at(int i) => (i >= 0 && i < text.length) ? text[i] ?? '' : '';
      out.add(ImportRow(
        registerNumber: at(iReg),
        name: at(iName),
        department: at(iDept),
        currentYear: parseYearInt(at(iCurr)),
        batchStartYear: parseYearInt(at(iStart)),
        batchEndYear: parseYearInt(at(iEnd)),
        photoUrl: at(iPhoto).isEmpty ? null : at(iPhoto),
      ));
    }
    return out;
  }
  return const <ImportRow>[];
}