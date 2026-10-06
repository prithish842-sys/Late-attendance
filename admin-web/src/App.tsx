import { Navigate, Outlet, Route, Routes } from "react-router-dom";
import type { ReactNode } from "react";
import { useAuth } from "./auth/AuthContext";
import { Layout } from "./components/Layout";
import { canOpenSettings } from "./lib/routes";
import { Audit } from "./pages/Audit";
import { Dashboard } from "./pages/Dashboard";
import { Login } from "./pages/Login";
import { Reports } from "./pages/Reports";
import { Settings } from "./pages/Settings";

function Gate() {
  const { user, loading } = useAuth();
  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-cream-50">
        <span aria-label="Loading" className="h-6 w-6 animate-spin rounded-full border-2 border-sand-200 border-t-maroon-900" />
      </div>
    );
  }
  if (user === null) return <Navigate to="/login" replace />;
  return <Outlet />;
}

/** V2 defense-in-depth: role-gate admin-only routes at the router level. */
function AdminOnly({ children }: { children: ReactNode }) {
  const { role } = useAuth();
  if (!canOpenSettings(role)) return <Navigate to="/" replace />;
  return <>{children}</>;
}

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route element={<Gate />}>
        <Route element={<Layout />}>
          <Route path="/" element={<Dashboard />} />
          <Route path="/reports" element={<Reports />} />
          <Route
            path="/settings"
            element={
              <AdminOnly>
                <Settings />
              </AdminOnly>
            }
          />
          <Route path="/audit" element={<Audit />} />
        </Route>
      </Route>
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}