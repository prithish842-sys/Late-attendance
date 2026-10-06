/// Runtime feature flags for the app.
///
/// `blazeEnabled` is the single switch that routes Spark-fallback behaviour to
/// real Google-cloud behaviour (docs/NOTES.md "Blaze switch"). Everything that
/// is Spark-limited on the free tier goes through an abstraction and picks its
/// implementation from this flag — no call-site changes needed when it flips.
///
/// Build the app with Blaze routing:
///   flutter build apk --dart-define=BLAZE_ENABLED=true
class AppConfig {
  const AppConfig._();

  static const bool blazeEnabled = bool.fromEnvironment(
    'BLAZE_ENABLED',
    defaultValue: false,
  );

  /// Firestore database id this project uses.
  ///
  /// Google names the auto-created database `(default)`, but this project's
  /// database was created as plain `default` (verified via the Firestore
  /// REST API — `databases/(default)` returns 404, `databases/default`
  /// returns the live NATIVE database). Every server-side script already
  /// hardcodes the real id (see `scripts/process-*.js` and
  /// `scripts/lib/firebase-rest.js`), so the app must name it too or every
  /// read/write fails with `NOT_FOUND: database (default) does not exist`.
  ///
  /// Override for a project that *does* use the stock name:
  ///   flutter run --dart-define=FIRESTORE_DATABASE_ID=(default)
  static const String firestoreDatabaseId = String.fromEnvironment(
    'FIRESTORE_DATABASE_ID',
    defaultValue: 'default',
  );
}