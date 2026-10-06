import 'package:flutter_test/flutter_test.dart';
import 'package:late_attendance/src/models/app_models.dart';
import 'package:late_attendance/src/services/report_pdf_builder.dart';

/// In-app PDF generation (NEW request 3): the builder must produce a real
/// `%PDF-` document from report rows with the same slug rule the office-side
/// generator uses (functions/report-core.js reportFileNameBase).
void main() {
  group('report_pdf_builder', () {
    List<ReportRow> twoRows() => const [
          ReportRow(
            date: '2026-09-28',
            time: '09:15',
            studentId: '26BSC008',
            name: 'BHAGYADHARSHINI V',
            department: 'B.SC CS',
            year: '1st Year',
          ),
          ReportRow(
            date: '2026-09-28',
            time: '09:20',
            studentId: '26IT002',
            name: 'SAMPLE STUDENT',
            department: 'B.SC IT',
            year: '2nd Year',
          ),
        ];

    test('builds a valid PDF with rows + stats', () async {
      final rows = twoRows();
      final bytes = await buildReportPdfBytes(
        rows: rows,
        stats: summarizeReport(rows),
        label: '28 September 2026',
      );
      expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
      expect(bytes.length, greaterThan(1000));
    });

    test('empty report still yields a PDF (friendly note, no table)', () async {
      final bytes = await buildReportPdfBytes(
        rows: const [],
        stats: summarizeReport(const []),
        label: '27 September 2026',
      );
      expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
    });

    test('reportPdfFileName mirrors the server slug rule', () {
      expect(
        reportPdfFileName('28 September 2026'),
        'late-attendance-28-september-2026.pdf',
      );
      expect(
        reportPdfFileName('21 September 2026 — B.Sc CS — 1st Year'),
        'late-attendance-21-september-2026-b-sc-cs-1st-year.pdf',
      );
      expect(reportPdfFileName(''), 'late-attendance-report.pdf');
    });
  });
}
