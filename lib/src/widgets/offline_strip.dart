import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/app_models.dart';
import '../services/scan_service.dart';
import '../services/sync_service.dart';
import '../theme/app_theme.dart';

/// Phase 5 status strip (docs/TASKS.md). Hides entirely when online with
/// nothing pending; when offline (or scans are still draining after a
/// reconnect) it shows a navy strip so the operator never mistakes "accepted,
/// syncing later" for "on the record now" (DESIGN.md §3 — one accent, plain
/// language). Shared by the dashboard and the scanner, both of which need to
/// report the same offline truth.
class OfflineStrip extends StatefulWidget {
  const OfflineStrip({super.key, required this.scan, this.sync});

  final ScanService scan;
  final SyncService? sync;

  @override
  State<OfflineStrip> createState() => _OfflineStripState();
}

class _OfflineStripState extends State<OfflineStrip> {
  // QA fix: cache the streams once. `ScanService.onlineStream` builds a new
  // underlying stream on every getter call, so a plain StreamBuilder re-subscribed
  // (and tore down) a live connectivity stream on EVERY parent rebuild — and
  // the dashboard rebuilds 1x/second.
  late final Stream<bool> _onlineStream = widget.scan.onlineStream;
  late final Stream<SyncResult>? _syncStream = widget.sync?.onSync;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: _onlineStream,
      builder: (context, onlineSnapshot) {
        final online = onlineSnapshot.hasData && onlineSnapshot.data!;
        return StreamBuilder<SyncResult>(
          stream: _syncStream,
          builder: (context, syncSnapshot) {
            final pending = widget.scan.pendingCount();
            final visible = (!online || pending > 0) &&
                !(onlineSnapshot.hasError && pending == 0);
            if (!visible) return const SizedBox.shrink();

            final message = !online
                ? pending > 0
                    ? 'Offline — $pending scan${pending == 1 ? '' : 's'} saved and syncing when back online.'
                    : 'Offline — scans are saved and sync automatically when back online.'
                : 'Syncing — $pending scan${pending == 1 ? '' : 's'} waiting to upload.';

            return Container(
              width: double.infinity,
              color: AppColors.navy900,
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              child: Text(
                message,
                style: GoogleFonts.inter(color: Colors.white, fontSize: 14),
              ),
            );
          },
        );
      },
    );
  }
}
