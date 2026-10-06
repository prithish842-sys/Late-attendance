import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/auth_service.dart';
import '../services/login_throttle.dart';
import '../theme/app_theme.dart';
import '../widgets/sankara_crest.dart';

/// PT sir's login. Email + password only (Firebase Auth, Email/Password was
/// confirmed enabled). Errors are plain-language, never technical.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth, this.throttle});

  final AuthService auth;

  /// 5 failures / 15 min client-side lockout (C1). Injectable for tests.
  /// The actual instance is owned by the State (`late final`) so a parent
  /// rebuild that constructs a new widget can never reset an in-flight ledger
  /// (review finding MEDIUM). Firebase Auth's own rate limiting remains the
  /// server-side backstop.
  final LoginThrottle? throttle;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final LoginThrottle _throttle = widget.throttle ?? LoginThrottle();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    final locked = _throttle.lockedRemaining(DateTime.now());
    if (locked != null) {
      setState(() => _error = LoginThrottle.lockMessage(locked));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await widget.auth.signIn(email: email, password: password);
    if (!mounted) return;
    String? error;
    if (outcome.ok) {
      _throttle.recordSuccess();
    } else if (outcome.countsAsFailure) {
      final remaining = _throttle.recordFailure(DateTime.now());
      error = remaining != null ? LoginThrottle.lockMessage(remaining) : outcome.message;
    } else {
      // Network / Firebase's own throttle: show it, never ledger it
      // (review finding HIGH-3 — offline must not lock you out).
      error = outcome.message;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              const SankaraCrest(size: 44),
              const Spacer(),
              Text(
                'Sankara College of Science & Commerce',
                style: displayStyle,
              ),
              const SizedBox(height: 10),
              Text(
                'Sign in to take the late attendance.',
                style: GoogleFonts.inter(
                  fontSize: 17,
                  color: AppColors.ink900,
                ),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                maxLength: 254,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'you@sankara.ac.in',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _password,
                obscureText: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _signIn(),
                decoration: const InputDecoration(
                  labelText: 'Password',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(
                  _error!,
                  style: GoogleFonts.inter(
                    color: AppColors.statusEscalate,
                    fontSize: 14,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _signIn,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Sign in'),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}