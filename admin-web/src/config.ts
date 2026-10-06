export interface FirebaseWebConfig {
  apiKey: string;
  authDomain: string;
  projectId: string;
  storageBucket: string;
  messagingSenderId: string;
  appId: string;
  measurementId?: string;
}

/** Google project web-app SDK config (see admin-web/.env / .env.example). */
export const firebaseWebConfig: FirebaseWebConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY ?? "",
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN ?? "",
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID ?? "",
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET ?? "",
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID ?? "",
  appId: import.meta.env.VITE_FIREBASE_APP_ID ?? "",
  measurementId: import.meta.env.VITE_FIREBASE_MEASUREMENT_ID ?? undefined,
};

/**
 * Mirror of the Flutter app's AppConfig.blazeEnabled flag (docs/NOTES.md
 * "Blaze switch"). false (Spark) = enqueue report_requests; true (Blaze) =
 * call the generateReport HttpsCallable. Set VITE_BLAZE_ENABLED=true when the
 * project upgrades to Blaze.
 */
export function isBlazeEnabled(): boolean {
  return (import.meta.env.VITE_BLAZE_ENABLED ?? "false") === "true";
}