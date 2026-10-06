import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import 'firebase_options.dart';
import 'src/screens/dashboard_screen.dart';
import 'src/screens/login_screen.dart';
import 'src/services/auth_service.dart';
import 'src/services/connectivity_service.dart';
import 'src/services/firestore_service.dart';
import 'src/services/offline_store.dart';
import 'src/services/perf_log.dart';
import 'src/services/scan_service.dart';
import 'src/services/sync_service.dart';
import 'src/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PerfLog.start('cold-start (main -> first frame)');
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Phase 5 offline store lives in the app-support directory (survives
  // restarts); open before the UI so the roster cache is ready immediately.
  Hive.init(await defaultHiveDirectory());
  runApp(const LateAttendanceApp());
}

class LateAttendanceApp extends StatelessWidget {
  const LateAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sankara Late Attendance',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const AuthGate(),
    );
  }
}

/// Routes between login and the PT Sir dashboard based on the signed-in user,
/// and owns the Phase 5 service graph (offline store → scan service → sync
/// service) so sync-on-reconnect lives for exactly as long as the session.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, this.auth, this.firestore, this.connectivity, this.offline, this.scan, this.sync});

  final AuthService? auth;
  final FirestoreService? firestore;

  /// Test seams: when omitted (production) the real ConnectivityService +
  /// HiveOfflineStore + derived ScanService/SyncService are built.
  final ConnectivityService? connectivity;
  final OfflineStore? offline;
  final ScanService? scan;
  final SyncService? sync;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final AuthService _auth;
  late final FirestoreService _firestore;
  late final ConnectivityService _connectivity;
  ScanService? _scan;
  SyncService? _sync;
  bool _ready = false;
  StreamSubscription<String?>? _userSub;
  String? _lastUserId;

  @override
  void initState() {
    super.initState();
    _auth = widget.auth ?? FirebaseAuthService();
    _firestore = widget.firestore ?? FirebaseFirestoreService();
    _connectivity = widget.connectivity ?? ConnectivityService();

    _userSub = _auth.userIdStream.listen((userId) {
      _lastUserId = userId;
      if (userId != null) {
        _sync?.start();
      } else {
        _sync?.stop();
      }
    });

    if (widget.scan != null && widget.sync != null) {
      _scan = widget.scan;
      _sync = widget.sync;
      _ready = true;
    } else {
      _buildServices();
    }
  }

  Future<void> _buildServices() async {
    final offline = widget.offline ?? await HiveOfflineStore.open();
    if (!mounted) return;
    final scan = ScanService(firestore: _firestore, offline: offline, connectivity: _connectivity);
    final sync = SyncService(scan: scan, offline: offline, connectivity: _connectivity);
    setState(() {
      _scan = scan;
      _sync = sync;
      _ready = true;
    });
    if (_lastUserId != null) sync.start();
  }

  @override
  void dispose() {
    _userSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: AppColors.maroon900),
        ),
      );
    }
    // QA: close the cold-start span on the first frame past service wiring.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PerfLog.stop('cold-start (main -> first frame)');
    });
    return StreamBuilder<String?>(
      stream: _auth.userIdStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            body: Center(
              child: CircularProgressIndicator(color: AppColors.maroon900),
            ),
          );
        }
        final userId = snapshot.data;
        if (userId == null) {
          return LoginScreen(auth: _auth);
        }
        return DashboardScreen(
          auth: _auth,
          firestore: _firestore,
          scan: _scan!,
          sync: _sync!,
          userId: userId,
        );
      },
    );
  }
}