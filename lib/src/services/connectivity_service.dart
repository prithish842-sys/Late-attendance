import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Phase 5 online/offline source (docs/TASKS.md). connectivity_plus reports the
/// OS network state as a strong primary signal; genuine Firestore network
/// failures while "connected" are a functional fallback so a dead VPN, captive
/// portal or flaky radio still falls back to queuing rather than throwing.
///
/// Production uses the platform [Connectivity]. Tests can inject `check`/
/// `changes` stubs instead (or nothing — a missing plugin reports online).
class ConnectivityService {
  ConnectivityService({this.connectivity, this.check, this.changes});

  final Connectivity? connectivity;
  final Future<List<ConnectivityResult>> Function()? check;
  final Stream<List<ConnectivityResult>> Function()? changes;

  /// Current best guess: any non-none connectivity result. When the plugin is
  /// unavailable (widget tests, exotic platforms) it reports online so scans
  /// keep their Phase-1 behavior and queueing stays a pure fallback.
  Future<bool> isOnline() async {
    try {
      final platform = connectivity;
      if (platform != null) {
        final results = await platform.checkConnectivity();
        return results.any((r) => r != ConnectivityResult.none);
      }
      final stub = check;
      if (stub != null) {
        final results = await stub();
        return results.any((r) => r != ConnectivityResult.none);
      }
      return true;
    } on Object {
      return true;
    }
  }

  /// Emits the current state immediately, then on every OS-level change.
  /// A broken/missing platform stream silently ends the stream rather than
  /// crashing the offline banner — the Firestore-error fallback still covers
  /// genuinely dead networks.
  Stream<bool> stream() async* {
    yield await isOnline();
    try {
      Stream<List<ConnectivityResult>> changesStream;
      final platform = connectivity;
      if (platform != null) {
        changesStream = platform.onConnectivityChanged;
      } else {
        final stubStream = changes;
        if (stubStream == null) return;
        changesStream = stubStream();
      }
      await for (final results in changesStream) {
        yield results.any((r) => r != ConnectivityResult.none);
      }
    } on Object {
      // No plugin / platform stream — banner goes quiet; wires never tear.
    }
  }

  /// True when an exception should be treated as "no network" rather than an
  /// application/permission error. Offline scans must never swallow a
  /// permission-denied or a validation failure — those rethrow (ScanService).
  static bool looksLikeOffline(Object error) {
    if (error is FirebaseException) {
      // `unknown` is included on purpose: a DNS/transport failure that the
      // SDK cannot map to a gRPC status arrives as `cloud_firestore/unknown`
      // (seen live on 2026-09-28 with a dead resolver) and must fall back to
      // queuing like any other network failure — permission/validation errors
      // keep their own codes and still rethrow.
      return const {
        'unavailable',
        'network-request-failed',
        'deadline-exceeded',
        'unknown',
      }.contains(error.code);
    }
    final message = error.toString().toLowerCase();
    return message.contains('socketexception') || message.contains('connection');
  }
}