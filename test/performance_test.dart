import 'package:flutter_test/flutter_test.dart';

import 'package:late_attendance/src/models/app_models.dart';
import 'package:late_attendance/src/services/import_parser.dart';

/// Phase 5 performance tests (NEW_TASKS.md "performance tests").
///
/// The four cheap hot-path helpers (chunkRegNumber, yearTier, monthKey,
/// reportMailRange) and the three heavy aggregation/builds (weeklyAuditOverview,
/// buildWeeklyAuditBodyPreview, validateImportRows with its 500-row cap) get
/// large synthetic inputs and generous Stopwatch ceilings. Like the Node
/// counterpart (functions/test/performance.test.js) this is a regression cage
/// against accidental O(n²) blow-ups, not a micro-benchmark — the ceilings are
/// deliberately seconds, so normal CI variance never flakes a bound.
void main() {
  final weekStart = DateTime(2026, 9, 21); // a Monday

  List<ReportRow> weeklyRows(int departments, int rowsPerDept, int students) {
    final rows = <ReportRow>[];
    for (var d = 0; d < departments; d++) {
      final dept = 'BSC-${String.fromCharCode(65 + d)}';
      for (var i = 0; i < rowsPerDept; i++) {
        final s = i % students;
        rows.add(ReportRow(
          date: '2026-09-${((i % 7) + 21).toString().padLeft(2, '0')}',
          time: '08:30',
          studentId: '$dept${(s + 1).toString().padLeft(3, '0')}',
          name: 'Student $dept-$s',
          department: dept,
          year: '${(i % 3) + 1}st Year',
        ));
      }
    }
    return rows;
  }

  test('weekly audit aggregation of 15k rows across 25 departments stays linear', () {
    final rows = weeklyRows(25, 600, 400); // 15,000 rows, 10,000 distinct
    final sw = Stopwatch()..start();
    final overview = weeklyAuditOverview(rows, weekStart);
    sw.stop();

    expect(overview.totalEvents, 15000);
    expect(overview.uniqueStudents, 10000);
    expect(overview.repeatedStudents, 5000, reason: '200 of 400 repeated per dept');
    expect(overview.departments.length, 25);
    for (var i = 1; i < overview.departments.length; i++) {
      final prev = overview.departments[i - 1];
      final cur = overview.departments[i];
      expect(
        prev.uniqueStudents > cur.uniqueStudents ||
            (prev.uniqueStudents == cur.uniqueStudents &&
                prev.totalEvents >= cur.totalEvents),
        isTrue,
        reason: 'departments sorted unique desc, then events desc',
      );
    }
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('weekly audit body preview renders a 2000-student repeated table', () {
    final rows = weeklyRows(1, 2400, 400); // 6 repeats for 400 students
    final overview = weeklyAuditOverview(rows, weekStart);
    final group = overview.departments.single;
    expect(group.repeatedStudents, 400);

    final sw = Stopwatch()..start();
    final body = buildWeeklyAuditBodyPreview(
      department: 'B.Sc Computer Science',
      weekStart: weekStart,
      group: group,
    );
    sw.stop();

    expect(body, contains('${group.uniqueStudents} students'));
    expect(body, contains('${group.totalEvents} occasions'));
    expect(body.split('\n').length, greaterThan(400), reason: 'one line per repeated student');
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });

  test('import sheet validation caps 1000 rows at the 500-row limit', () {
    final departments = [DepartmentInfo(id: 'BSC-CS', name: 'B.Sc Computer Science', hodEmail: 'hod@x.in')];
    final rows = List.generate(1000, (i) => ImportRow(
          registerNumber: '24BCS${(i + 1).toString().padLeft(3, '0')}',
          name: 'Student $i',
          department: 'B.Sc Computer Science',
          currentYear: 1,
          batchStartYear: 2024,
          batchEndYear: 2027,
        ));

    final sw = Stopwatch()..start();
    final result = validateImportRows(rows, departments: departments, existingStudentIds: const []);
    sw.stop();

    expect(result.counts.rows, 500, reason: 'only the first 500 are validated');
    expect(result.counts.valid, 500);
    expect(result.counts.invalid, 0);
    expect(sw.elapsedMilliseconds, lessThan(3000));
  });

  test('hot-path formatting helpers scale linearly over 30k samples', () {
    // Deliberately loose: the first call pays the JIT warm-up, so this only
    // catches true O(n²) blow-ups, never microseconds.
    final registers = List.generate(30000, (i) => '24BCS${i.toString().padLeft(4, '0')}');
    final years = List.generate(30000, (i) => ['1st', '2nd', 'III', 'II', '2024-2027', 'I'][i % 6]);
    final dates = List.generate(30000, (i) => DateTime(2026, 9, (i % 7) + 21, 8, 30));

    final sw = Stopwatch()..start();
    var tierSum = 0;
    var chunked = 0;
    var keys = 0;
    for (var i = 0; i < years.length; i++) {
      tierSum += yearTier(years[i]);
      chunked += chunkRegNumber(registers[i]).length;
      keys += monthKey(dates[i]).length;
    }
    sw.stop();

    expect(tierSum, greaterThan(0));
    expect(chunked, greaterThan(0));
    expect(keys, greaterThan(0));
    expect(chunkRegNumber('24BCS0001'), contains(' '));
    expect(sw.elapsedMilliseconds, lessThan(10000));
  });
}