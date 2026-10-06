import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import { onAuthStateChanged, signInWithEmailAndPassword, signOut as fbSignOut } from "firebase/auth";
import type { User } from "firebase/auth";
import { doc, getDoc } from "firebase/firestore";
import { auth, db } from "../fb";
import { signInFailure } from "../lib/describeAuthError";
import type { SignInFailure } from "../lib/describeAuthError";

interface AuthState {
  user: User | null;
  role: string | null;
  staffName: string | null;
  loading: boolean;
  signIn: (email: string, password: string) => Promise<SignInFailure | null>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [role, setRole] = useState<string | null>(null);
  const [staffName, setStaffName] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const unsubscribe = onAuthStateChanged(auth, async (u) => {
      setUser(u);
      if (u === null) {
        setRole(null);
        setStaffName(null);
        setLoading(false);
        return;
      }
      try {
        const id = await u.getIdTokenResult();
        setRole(typeof id.claims.role === "string" ? id.claims.role : null);
      } catch {
        setRole(null);
      }
      try {
        const snap = await getDoc(doc(db, "staff", u.uid));
        setStaffName(snap.exists() ? (typeof snap.data().name === "string" ? snap.data().name : null) : null);
      } catch {
        setStaffName(null);
      }
      setLoading(false);
    });
    return unsubscribe;
  }, []);

  const signIn = useCallback(async (email: string, password: string): Promise<SignInFailure | null> => {
    try {
      await signInWithEmailAndPassword(auth, email, password);
      return null;
    } catch (e) {
      return signInFailure(e);
    }
  }, []);

  const signOut = useCallback(async () => {
    await fbSignOut(auth);
  }, []);

  const value = useMemo<AuthState>(
    () => ({ user, role, staffName, loading, signIn, signOut }),
    [user, role, staffName, loading, signIn, signOut],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (ctx === null) throw new Error("useAuth must be used inside AuthProvider");
  return ctx;
}