import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:printing/printing.dart';

import '../theme/app_theme.dart';

/// Full-screen PDF viewer + save/share for a report built in-app
/// (report_pdf_builder.dart). PdfPreview rasterises every page on-device, so
/// there is no server, no office machine and no network involved; the action
/// bar (and the AppBar share button) hand the bytes to Android's share sheet,
/// where PT sir can save to Files, send to a printer, or share out.
class ReportPdfViewerScreen extends StatelessWidget {
  const ReportPdfViewerScreen({
    super.key,
    required this.bytes,
    required this.fileName,
    this.periodLabel,
  });

  final Uint8List bytes;

  /// e.g. `late-attendance-28-september-2026.pdf` (reportPdfFileName).
  final String fileName;

  /// Human-readable window label for the app bar.
  final String? periodLabel;

  Future<void> _share() =>
      Printing.sharePdf(bytes: bytes, filename: fileName);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEEF1F6),
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back, color: AppColors.navy900),
          onPressed: () => Navigator.of(context).pop(),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Attendance report',
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.navy900,
              ),
            ),
            if (periodLabel != null)
              Text(
                periodLabel!,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: AppColors.ink900.withValues(alpha: 0.6),
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Save or share',
            icon: const Icon(Icons.ios_share, color: AppColors.navy900),
            onPressed: _share,
          ),
        ],
      ),
      body: PdfPreview(
        build: (format) async => bytes,
        pdfFileName: fileName,
        canChangePageFormat: false,
        canChangeOrientation: false,
        allowPrinting: true,
        allowSharing: true,
        actionBarTheme: PdfActionBarTheme(
          backgroundColor: AppColors.maroon900,
          iconColor: Colors.white,
          textStyle: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
