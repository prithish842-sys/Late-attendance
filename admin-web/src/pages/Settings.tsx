import { useEffect, useState } from "react";
import { useAuth } from "../auth/AuthContext";
import { loadDepartments, loadSettings, saveDepartmentHodEmail, saveSettings } from "../lib/firestore";
import type { Department } from "../lib/report";
import type { SettingsDoc } from "../lib/firestore";
import { Notice, PrimaryButton, SectionTitle, selectClass, inputClass, Spinner } from "../components/Ui";

const DEFAULT: SettingsDoc = { escalationThreshold: 3, resetPeriod: "monthly", lateCutoffTime: null };

/** Settings - admin-only writes (firestore.rules enforces the gate server-side too). */
export function Settings() {
  const { role } = useAuth();
  const isAdmin = role === "admin";

  const [settings, setSettings] = useState<SettingsDoc>(DEFAULT);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [hodEmailByDept, setHodEmailByDept] = useState<Record<string, string>>({});
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    Promise.all([loadSettings(), loadDepartments()])
      .then(([s, depts]) => {
        if (!active) return;
        setSettings(s);
        setDepartments(depts);
        setHodEmailByDept(Object.fromEntries(depts.map((d) => [d.id, d.hodEmail ?? ""])));
        setLoaded(true);
      })
      .catch(() => {
        if (active) setError("Couldn\u2019t load settings. Check the network and try again.");
      });
    return () => {
      active = false;
    };
  }, []);

  function setThreshold(raw: string) {
    const n = Number(raw);
    if (Number.isNaN(n)) return;
    setSettings((s) => ({ ...s, escalationThreshold: Math.max(1, Math.min(99, Math.round(n))) }));
  }

  const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

  async function save() {
    if (busy || !isAdmin) return;
    setBusy(true);
    setNotice(null);
    setError(null);
    try {
      // C4: validate every CHANGED HOD address up front so one typo aborts
      // the whole save instead of half-writing bad values. Unchanged values
      // never block the save, and clearing to empty is always allowed
      // (review finding LOW).
      for (const d of departments) {
        const next = (hodEmailByDept[d.id] ?? "").trim();
        if (next !== (d.hodEmail ?? "") && next !== "" && !EMAIL_RE.test(next)) {
          setError(`The HOD email for ${d.name} doesn\u2019t look like an email address.`);
          return;
        }
      }
      await saveSettings({
        escalationThreshold: settings.escalationThreshold,
        resetPeriod: settings.resetPeriod,
        lateCutoffTime: settings.lateCutoffTime === "" ? null : settings.lateCutoffTime,
      });
      for (const d of departments) {
        const next = (hodEmailByDept[d.id] ?? "").trim();
        if (next !== (d.hodEmail ?? "")) {
          await saveDepartmentHodEmail(d.id, next);
        }
      }
      setDepartments((prev) =>
        prev.map((d) => ({ ...d, hodEmail: (hodEmailByDept[d.id] ?? "").trim() || null })),
      );
      setNotice("Settings saved.");
    } catch {
      setError("The settings couldn\u2019t be saved \u2014 check the network and try again.");
    } finally {
      setBusy(false);
    }
  }

  if (!loaded) {
    return (
      <div className="flex justify-center py-20">
        <Spinner />
      </div>
    );
  }

  return (
    <div>
      <SectionTitle
        title="Settings"
        subtitle="Only administrators can change these."
      />

      <div className="max-w-2xl space-y-5">
        <div className="rounded-md border border-sand-200 bg-white p-5">
          <p className="mb-4 text-sm font-semibold text-navy-900">Escalation rules</p>
          <div className="grid gap-4 sm:grid-cols-2">
            <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
              Late counts before an HOD mail
              <input
                className={inputClass}
                type="number"
                min={1}
                max={99}
                value={settings.escalationThreshold}
                onChange={(e) => setThreshold(e.target.value)}
                disabled={!isAdmin}
              />
              <span className="text-xs text-ink-900/60">
                On this many lates in one month the student is escalated (default 3).
              </span>
            </label>
            <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
              Count reset period
              <select
                className={selectClass}
                value={settings.resetPeriod}
                onChange={(e) => setSettings((s) => ({ ...s, resetPeriod: e.target.value }))}
                disabled={!isAdmin}
              >
                <option value="monthly">Monthly</option>
                <option value="semester">Per semester</option>
              </select>
              <span className="text-xs text-ink-900/60">Monthly is the current default (DECISIONS.md #1).</span>
            </label>
          </div>
          <label className="mt-4 flex flex-col gap-1.5 text-sm text-ink-900/70">
            Late cutoff time
            <input
              className={inputClass}
              type="time"
              value={settings.lateCutoffTime ?? ""}
              onChange={(e) => setSettings((s) => ({ ...s, lateCutoffTime: e.target.value }))}
              disabled={!isAdmin}
            />
            <span className="text-xs text-ink-900/60">
              College starts at 9:45 AM - scanning any time records a late entry. This value is stored for
              a future reintroduction (DECISIONS.md #3); the app does not apply it.
            </span>
          </label>
        </div>

        <div className="rounded-md border border-sand-200 bg-white p-5">
          <p className="mb-1 text-sm font-semibold text-navy-900">HOD email addresses</p>
          <p className="mb-4 text-xs text-ink-900/60">
            Escalation mail for each department goes to its head of department.
          </p>
          <div className="space-y-3">
            {departments.map((d) => (
              <label key={d.id} className="flex flex-col gap-1.5 text-sm text-ink-900/70">
                {d.name} ({d.id})
                <input
                  className={inputClass}
                  type="email"
                  maxLength={254}
                  placeholder="hod@sankara.ac.in"
                  value={hodEmailByDept[d.id] ?? ""}
                  onChange={(e) =>
                    setHodEmailByDept((prev) => ({ ...prev, [d.id]: e.target.value }))
                  }
                  disabled={!isAdmin}
                />
              </label>
            ))}
          </div>
        </div>

        {isAdmin ? (
          <div className="flex flex-wrap items-center gap-4">
            <PrimaryButton onClick={save} busy={busy} disabled={!isAdmin}>
              Save settings
            </PrimaryButton>
            {notice ? <Notice>{notice}</Notice> : null}
            {error ? <Notice kind="error">{error}</Notice> : null}
          </div>
        ) : null}
      </div>
    </div>
  );
}