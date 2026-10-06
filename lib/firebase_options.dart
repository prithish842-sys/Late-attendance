// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for ios - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.macOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for macos - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.windows:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for windows - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAc4FUfSLHKAvHNFedLYZDOK4AATJTLpog',
    appId: '1:585065428392:android:0118a5f8aa5c75406cd99d',
    messagingSenderId: '585065428392',
    projectId: 'late-attendance-5bf6d',
    databaseURL: 'https://late-attendance-5bf6d-default-rtdb.asia-southeast1.firebasedatabase.app',
    storageBucket: 'late-attendance-5bf6d.firebasestorage.app',
  );
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCgq_7YO2sGZSLT5jE_MijWcB9JES8WIIc',
    appId: '1:585065428392:web:b064992c34436a126cd99d',
    messagingSenderId: '585065428392',
    projectId: 'late-attendance-5bf6d',
    authDomain: 'late-attendance-5bf6d.firebaseapp.com',
    databaseURL: 'https://late-attendance-5bf6d-default-rtdb.asia-southeast1.firebasedatabase.app',
    storageBucket: 'late-attendance-5bf6d.firebasestorage.app',
    measurementId: 'G-TMD8Z8JM64',
  );
}
