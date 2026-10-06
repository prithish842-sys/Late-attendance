import { NavLink, Outlet } from "react-router-dom";
import { useAuth } from "../auth/AuthContext";
import { canOpenSettings } from "../lib/routes";
import { Crest } from "./Crest";

const NAV: { to: string; label: string; end?: boolean; adminOnly?: boolean }[] = [
  { to: "/", label: "Dashboard", end: true },
  { to: "/reports", label: "Reports" },
  { to: "/settings", label: "Settings", adminOnly: true },
  { to: "/audit", label: "Audit log" },
];

const ROLE_LABELS: Record<string, string> = {
  pt_sir: "Gate office",
  admin: "Administrator",
};

/** Left-aligned nav with the crest at top; dense content to the right (DESIGN.md §3.2). */
export function Layout() {
  const { user, staffName, role, signOut } = useAuth();
  return (
    <div className="flex min-h-screen">
      <aside className="flex w-64 shrink-0 flex-col border-r border-sand-200 bg-white">
        <div className="flex items-start gap-3 px-5 pb-5 pt-6">
          <Crest size={40} />
          <div>
            <p className="text-[15px] font-semibold leading-snug text-navy-900">
              Sankara College of Science &amp; Commerce
            </p>
            <p className="mt-1 text-xs text-ink-900/60">Late attendance</p>
          </div>
        </div>
        <nav className="flex-1 px-3 pt-2">
          {NAV.filter((item) => !item.adminOnly || canOpenSettings(role)).map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.end}
              className={({ isActive }) =>
                `mb-1 block rounded-md px-3 py-2 text-sm font-medium ${
                  isActive ? "bg-maroon-900 text-white" : "text-ink-900 hover:bg-sand-200"
                }`
              }
            >
              {item.label}
            </NavLink>
          ))}
        </nav>
        {user ? (
          <div className="border-t border-sand-200 px-5 py-4">
            <p className="truncate text-sm font-semibold text-ink-900">{staffName ?? user.email}</p>
            <p className="text-xs text-ink-900/60">{role ? ROLE_LABELS[role] ?? role : ""}</p>
            <button
              type="button"
              onClick={() => {
                void signOut();
              }}
              className="mt-3 text-sm font-semibold text-maroon-700 hover:text-maroon-900"
            >
              Sign out
            </button>
          </div>
        ) : null}
      </aside>
      <main className="min-w-0 flex-1 overflow-y-auto px-8 py-8">
        <Outlet />
      </main>
    </div>
  );
}