import { initializeApp } from "firebase/app";
import { getAuth } from "firebase/auth";
import { getFirestore } from "firebase/firestore";
import { firebaseWebConfig } from "./config";

export const app = initializeApp(firebaseWebConfig);
export const auth = getAuth(app);
// This project's Firestore database id is `default`, not Google's `(default)`
// (scripts/ and the Flutter app use the same id — see AppConfig.firestoreDatabaseId).
export const db = getFirestore(app, "default");