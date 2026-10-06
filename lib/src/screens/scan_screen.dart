import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/app_models.dart';
import '../services/auth_service.dart';
import '../services/connectivity_service.dart';
import '../services/firestore_service.dart';
import '../services/offline_store.dart';
import '../services/perf_log.dart';
import '../services/scan_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';
import '../widgets/offline_strip.dart';
import '../widgets/sankara_crest.dart';
import 'escalation_screen.dart';
import 'reports_screen.dart';
import 'verify_screen.dart';

typedef ScannerViewBuilder = Widget Function(
  MobileScannerController controller,
  ValueChanged<String> onBarcode,
  ValueChanged<Object> onDetectError,
);

/// The scanner (NEW_DESIGN.md §Scanner, NEW_TASKS.md Phase 1): a dominant,
/// familiar camera scanner first (Jacob's Law — viewfinder + torch), with the
/// manual Register Number box directly below it as the fallback. Errors stay
/// plain-language (DESIGN.md §5). Phase 5 adds the offline/sync strip under the
/// header so the operator always knows whether a scan landed immediately or is
/// queued for sync-on-reconnect.
class ScanScreen extends StatefulWidget {
  ScanScreen({
    super.key,
    required this.auth,
    required this.firestore,
    required this.userId,
    ScanService? scan,
    this.sync,
    this.scannerViewBuilder,
  }) : scan =
           scan ??
           ScanService(
             firestore: firestore,
             offline: MemoryOfflineStore(),
             connectivity: ConnectivityService(),
           );

  final AuthService auth;
  final FirestoreService firestore;
  final ScanService scan;
  final SyncService? sync;
  final ScannerViewBuilder? scannerViewBuilder;
  final String userId;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _manualController = TextEditingController();
  final _scannerController = MobileScannerController();
  String? _error;
  bool _torchOn = false;
  bool _processing = false;
  bool _manualEntryVisible = false;

  /// QA rate limit — see [_onCode]: one physical scan == one lookup.
  static const _sameCodeCooldown = Duration(seconds: 3);
  String? _lastScannedCode;
  DateTime? _lastScannedAt;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _manualController.dispose();
    _scannerController.dispose();
    // QA: flush the Firestore call table when the scanner closes (every pop).
    PerfLog.dumpDb('scan');
    super.dispose();
  }

  Future<void> _onCode(String code) async {
    final manual = code.trim();
    if (manual.isEmpty || _processing) return;
    // Rate limit: a camera held on an already-scanned card re-emits the same
    // barcode many times a second. Ignore a repeat of the last code for 3 s so
    // one physical scan is exactly one Firestore lookup.
    final now = DateTime.now();
    final lastCode = _lastScannedCode;
    if (lastCode == manual &&
        _lastScannedAt != null &&
        now.difference(_lastScannedAt!) < _sameCodeCooldown) {
      PerfLog.event('scan: duplicate "$manual" within cooldown — ignored');
      return;
    }
    _lastScannedCode = manual;
    _lastScannedAt = now;
    PerfLog.start('scan->verify-details');
    setState(() {
      _processing = true;
      _error = null;
    });
    await _pauseScanner();

    Student? student;
    try {
      student = await widget.scan.findStudentByCode(manual);
    } on Object {
      _showLookupFailure();
      await _resumeScanner();
      return;
    }
    if (!mounted) return;

    if (student == null) {
      _abortLookupSpans();
      setState(() {
        _error =
            'No student matches that ID — check the number and try again, '
            'or read the register number off the card below.';
        _processing = false;
        _manualEntryVisible = true;
      });
      await _resumeScanner();
      return;
    }
    if (_blockedIfInactive(student)) {
      await _resumeScanner();
      return;
    }

    _manualController.clear();
    setState(() => _manualEntryVisible = false);
    await _openVerify(student, scanMethod: 'barcode');
  }

  /// Phase 4 gate — an archived/passed-out student (active:false) is never
  /// scannable: show a distinct blocked message instead of the verify screen.
  bool _blockedIfInactive(Student student) {
    if (student.active) return false;
    _abortLookupSpans();
    setState(() {
      _processing = false;
      _error =
          '${student.name} has been archived — this record is no longer '
          'scannable. Restore it in Admin › Recently Deleted if needed.';
    });
    _manualController.clear();
    return true;
  }

  Future<void> _submitManual() async {
    if (_processing) return;
    final code = _manualController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the ID number first.');
      return;
    }
    // C4: register numbers/barcodes are at most 24 chars — checked HERE, not
    // with maxLength, so a long paste shows in full and gets a clear message
    // instead of silent truncation (review finding LOW).
    if (code.length > 24) {
      setState(() {
        _error = 'That ID number is too long \u2014 register numbers are 24 characters or fewer.';
      });
      return;
    }
    PerfLog.start('manual-id->verify-details');
    setState(() {
      _processing = true;
      _error = null;
    });
    await _pauseScanner();

    Student? student;
    try {
      student = await widget.scan.findStudentByCode(code);
    } on Object {
      _showLookupFailure();
      await _resumeScanner();
      return;
    }
    if (!mounted) return;
    if (student == null) {
      _abortLookupSpans();
      setState(() {
        _error =
            'No student matches that ID — check the number and try again.';
        _processing = false;
      });
      await _resumeScanner();
      return;
    }
    if (_blockedIfInactive(student)) {
      await _resumeScanner();
      return;
    }
    _manualController.clear();
    setState(() => _manualEntryVisible = false);
    await _openVerify(student, scanMethod: 'manual');
  }

  /// QA (debug only): decode the app-external QA barcode image through the
  /// detector and push the raw value into [_onCode] — the exact production
  /// path a camera detection takes (lookup → pause → verify navigation →
  /// spans). The still image exists because a headless driver cannot
  /// physically present a barcode to the camera. Lives in the app's own
  /// external files dir so scoped storage needs no permission. Compiled out
  /// of release builds by [kDebugMode].
  static const String _qaImagePath =
      '/storage/emulated/0/Android/data/com.example.late_attendance/files/qa_code.png';

  Future<void> _qaAnalyzePushedImage() async {
    if (!kDebugMode) return;
    PerfLog.event('qa: analyzeImage($_qaImagePath)');
    BarcodeCapture? capture;
    try {
      capture = await _scannerController.analyzeImage(_qaImagePath);
    } on Object catch (e) {
      // Some platform builds refuse analyzeImage while the camera stream is
      // live — stop, retry once, then let _onCode's own resume handle it.
      PerfLog.event('qa: analyzeImage failed (${e.runtimeType}) — retry after stop');
      try {
        await _scannerController.stop();
        capture = await _scannerController.analyzeImage(_qaImagePath);
      } on Object catch (e2) {
        PerfLog.event('qa: analyzeImage retry failed (${e2.runtimeType})');
        await _resumeScanner();
        return;
      }
    }
    final raw = capture?.barcodes
        .map((barcode) => barcode.rawValue)
        .firstWhere(
          (value) => value != null && value.isNotEmpty,
          orElse: () => null,
        );
    if (raw == null) {
      PerfLog.event('qa: analyzeImage decoded nothing');
      await _resumeScanner();
      return;
    }
    await _onCode(raw);
  }

  Future<void> _openVerify(
    Student student, {
    required String scanMethod,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VerifyScreen(
          firestore: widget.firestore,
          scan: widget.scan,
          sync: widget.sync,
          userId: widget.userId,
          student: student,
          scanMethod: scanMethod,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _processing = false);
    await _resumeScanner();
  }

  /// QA: close whichever lookup span is open when the flow never reaches the
  /// verify screen (lookup failed / unknown ID / archived student).
  void _abortLookupSpans() {
    PerfLog.stop('scan->verify-details');
    PerfLog.stop('manual-id->verify-details');
  }

  void _showLookupFailure() {
    _abortLookupSpans();
    if (!mounted) return;
    setState(() {
      _error = 'Student lookup failed. Check your connection or permissions and try again.';
      _processing = false;
      // Fallback path: let the register number typed off the card work even
      // when the network lookup just failed (offline cache is tried there too).
      _manualEntryVisible = true;
    });
  }

  Future<void> _pauseScanner() async {
    if (widget.scannerViewBuilder != null) return;
    try {
      await _scannerController.stop();
    } on Object {
      return;
    }
  }

  Future<void> _resumeScanner() async {
    if (!mounted || widget.scannerViewBuilder != null) return;
    try {
      await _scannerController.start();
    } on Object {
      return;
    }
  }

  void _onScannerError(Object _, StackTrace _) {
    _abortLookupSpans();
    if (!mounted) return;
    setState(() {
      _error = 'Barcode not readable \u2014 enter the register number from the card instead.';
      _processing = false;
      // Decode failed → reveal the manual/register-number path automatically.
      _manualEntryVisible = true;
    });
  }

  void _toggleTorch() {
    setState(() => _torchOn = !_torchOn);
    // Best effort — torch availability is device-specific; the toggle never
    // blocks scanning.
    _scannerController.toggleTorch().catchError((Object _) {});
  }

  Future<void> _openEscalations() async {
    await _pauseScanner();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EscalationScreen(
          auth: widget.auth,
          firestore: widget.firestore,
          userId: widget.userId,
        ),
      ),
    );
    await _resumeScanner();
  }

  Future<void> _openReports() async {
    await _pauseScanner();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReportsScreen(
          auth: widget.auth,
          firestore: widget.firestore,
          userId: widget.userId,
        ),
      ),
    );
    await _resumeScanner();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            OfflineStrip(scan: widget.scan, sync: widget.sync),
            Expanded(child: _buildScanner()),
            _buildManualEntry(),
            if (_error != null)
              Container(
                width: double.infinity,
                color: AppColors.statusEscalate.withValues(alpha: 0.10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Text(
                  _error!,
                  style: GoogleFonts.inter(
                    color: AppColors.ink900,
                    fontSize: 15,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 8, 6),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
            color: AppColors.navy900,
          ),
          const SankaraCrest(size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              // QA (debug only): long-press the title to run the still image at
              // /sdcard/qa_code.png through the detector (analyzeImage) and feed
              // the result into _onCode — the identical app-side path a camera
              // detection takes. kDebugMode nulls this on release builds.
              onLongPress: kDebugMode ? _qaAnalyzePushedImage : null,
              child: Text(
                'Scan Student',
                style: GoogleFonts.inter(
                  color: AppColors.navy900,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Attendance reports',
            onPressed: _openReports,
            icon: const Icon(Icons.insert_chart_outlined),
            color: AppColors.navy900,
          ),
          IconButton(
            tooltip: 'Escalations & HOD mail',
            onPressed: _openEscalations,
            icon: const Icon(Icons.mark_email_read_outlined),
            color: AppColors.navy900,
          ),
        ],
      ),
    );
  }

  Widget _buildScanner() {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child:
              widget.scannerViewBuilder?.call(
                _scannerController,
                _onCode,
                // StackTrace.empty: the builder adapter has no real stack —
                // _onScannerError only reads the error, never the trace.
                (e) => _onScannerError(e, StackTrace.empty),
              ) ??
              MobileScanner(
                controller: _scannerController,
                onDetect: (capture) {
                  final raw = capture.barcodes
                      .map((barcode) => barcode.rawValue)
                      .firstWhere(
                        (value) => value != null && value.isNotEmpty,
                        orElse: () => null,
                      );
                  if (raw != null) _onCode(raw);
                },
                onDetectError: _onScannerError,
                errorBuilder: (context, error) => _cameraError(),
              ),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: _torchOn ? 'Turn torch off' : 'Turn torch on',
              onPressed: _toggleTorch,
              icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
              color: Colors.white,
            ),
          ),
        ),
        if (_processing)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.45),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 12),
                    Text(
                      'Checking student\u2026',
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 14,
          child: IgnorePointer(
            child: Text(
              'Aim at the barcode or QR code on the ID card.',
              style: GoogleFonts.inter(color: Colors.white, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  Widget _cameraError() {
    return ColoredBox(
      color: AppColors.navy900,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.no_photography_outlined,
                color: Colors.white,
                size: 40,
              ),
              const SizedBox(height: 14),
              Text(
                'Camera unavailable. Enter the ID number instead.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() => _manualEntryVisible = true),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: const Text('Enter ID instead'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildManualEntry() {
    if (!_manualEntryVisible) {
      return ColoredBox(
        color: AppColors.cream50,
        child: Align(
          alignment: Alignment.center,
          child: TextButton(
            onPressed: _processing
                ? null
                : () => setState(() => _manualEntryVisible = true),
            child: const Text('Enter ID manually'),
          ),
        ),
      );
    }
    return Container(
      color: AppColors.cream50,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('manual-student-id'),
              controller: _manualController,
              textCapitalization: TextCapitalization.characters,
              keyboardType: TextInputType.text,
              // C4: no control characters can ever reach a lookup or the
              // queue; the 24-char bound is enforced in _submitManual so a
              // long paste is visible and explains itself (review LOW).
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'[\u0000-\u001F\u007F]')),
              ],
              style: GoogleFonts.inter(fontSize: 17, color: AppColors.ink900),
              decoration: const InputDecoration(
                hintText: 'Register number or barcode',
              ),
              onSubmitted: (_) => _submitManual(),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _processing ? null : _submitManual,
            child: const Text('Find student'),
          ),
        ],
      ),
    );
  }
}
