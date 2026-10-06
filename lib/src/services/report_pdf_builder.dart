import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/app_models.dart';

/// In-app PDF report builder — the Flutter mirror of the office-side
/// PDFKit generator (`functions/report-core.js buildReportPdf`), so PT sir
/// can generate and view a report on the phone without the office machine
/// (Spark plan — no Cloud Functions / Storage involved).
///
/// Same layout contract as the server file:
///   - A4, 40pt margins, Helvetica
///   - College header (14 bold navy), period line (10 maroon), stats line
///     (9 bold ink)
///   - dense per-entry table: Date 64 / Time 46 / Student ID 70 / Name 148 /
///     Department 110 / Year 40, navy header band, 8pt cells, header repeats
///     on every page (pdfkit's addPage loop == MultiPage paging)
///   - empty reports print a friendly note instead of a bare table
///   - CSS palette copied from functions/report-core.js
final PdfColor _ink = PdfColor.fromHex('#232323');
final PdfColor _navy = PdfColor.fromHex('#1B2A4A');
final PdfColor _maroon = PdfColor.fromHex('#8B1E1E');

const _headCells = ['Date', 'Time', 'Student ID', 'Name', 'Department', 'Year'];
final Map<int, pw.TableColumnWidth> _colWidths = {
  0: const pw.FixedColumnWidth(64),
  1: const pw.FixedColumnWidth(46),
  2: const pw.FixedColumnWidth(70),
  3: const pw.FixedColumnWidth(148),
  4: const pw.FixedColumnWidth(110),
  5: const pw.FixedColumnWidth(40),
};

final RegExp _beyondLatin1 = RegExp('[^\\u0000-\\u00FF]');

/// dart_pdf's built-in Helvetica (like pdfkit's WinAnsi Helvetica on the
/// server) can only draw Latin-1: typographic dashes/apostrophes are folded
/// to ASCII and anything beyond U+00FF is dropped, so a stray codepoint can
/// never silently blank out a cell ("Unable to find a font to draw ..." is
/// avoided entirely).
String _pdfText(String s) {
  var out = s
      .replaceAll('\u2014', '-')
      .replaceAll('\u2013', '-')
      .replaceAll('\u2018', "'")
      .replaceAll('\u2019', "'")
      .replaceAll('\u201C', '"')
      .replaceAll('\u201D', '"')
      .replaceAll('\u2026', '...')
      .replaceAll('\u00A0', ' ');
  out = out.replaceAll(_beyondLatin1, '');
  return out;
}

/// Builds the PDF bytes for a report. [label] is the human window/filters
/// string shown on the title line and echoed into the file name slug.
Future<Uint8List> buildReportPdfBytes({
  required List<ReportRow> rows,
  required ReportSummary stats,
  required String label,
}) async {
  final doc = pw.Document(title: 'Late Attendance Report $label');

  final titleStyle = pw.TextStyle(
    fontSize: 14,
    fontWeight: pw.FontWeight.bold,
    color: _navy,
  );
  final subtitleStyle = pw.TextStyle(fontSize: 10, color: _maroon);
  final statsStyle = pw.TextStyle(
    fontSize: 9,
    fontWeight: pw.FontWeight.bold,
    color: _ink,
  );

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (_) => [
        pw.Text(
          _pdfText('Sankara College of Science & Commerce'),
          style: titleStyle,
        ),
        pw.SizedBox(height: 3),
        pw.Text(_pdfText('Late Attendance Report - $label'), style: subtitleStyle),
        pw.SizedBox(height: 10),
        pw.Text(
          _pdfText(
            '${stats.totalLateEntries} late entries - '
            '${stats.distinctStudents} ${stats.distinctStudents == 1 ? 'student' : 'students'}',
          ),
          style: statsStyle,
        ),
        pw.SizedBox(height: 8),
        if (rows.isEmpty)
          pw.Text(
            'No late entries in this period.',
            style: pw.TextStyle(fontSize: 10, color: _ink),
          )
        else
          pw.TableHelper.fromTextArray(
            headers: _headCells,
            data: [
              for (final r in rows)
                [
                  _pdfText(r.date),
                  _pdfText(r.time),
                  _pdfText(r.studentId),
                  _pdfText(r.name),
                  _pdfText(r.department),
                  _pdfText(r.year ?? ''),
                ],
            ],
            columnWidths: _colWidths,
            headerStyle: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: const PdfColor(1, 1, 1),
            ),
            cellStyle: pw.TextStyle(fontSize: 8, color: _ink),
            headerDecoration: pw.BoxDecoration(color: _navy),
            headerAlignment: pw.Alignment.centerLeft,
            cellAlignment: pw.Alignment.centerLeft,
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 5,
              vertical: 3,
            ),
            border: const pw.TableBorder(),
          ),
      ],
    ),
  );

  return doc.save();
}

/// File name for the share/save sheet — same slug rule as the server's
/// `reportFileNameBase` (functions/report-core.js).
String reportPdfFileName(String label) {
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return 'late-attendance-${slug.isEmpty ? 'report' : slug}.pdf';
}
