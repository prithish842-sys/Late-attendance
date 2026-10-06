import { useEffect, useMemo, useState } from "react";
import { StatusBadge } from "../components/StatusBadge";
import { Card, DataTable, EmptyState, SectionTitle } from "../components/Ui";
import {
  fetchReportLogs,
  loadMailLogs,
  loadReportRequests,
  loadScansBetween,
  loadSettings,
} from "../lib/firestore";
import type { MailLogRow, ReportLogRow, ReportRequestRow, ScanRow } from "../lib/firestore";
import { dayKey } from "../lib/report";

type Tab = "scans" | "mail" | "reports";

const TABS: { value: Tab; label: string }[] = [
  { value: "scans", label: "Late scans" },
  { value: "mail", label: "Escalation mail" },
  { value: "reports", label: "Reports" },
];

function currentMonthRange(): { start: Date; end: Date } {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), 1);
  return { start, end: new Date(now.getFullYear(), now.getMonth() + 1, 1) };
}

/** Audit log - who scanned what, when (and the mail/report trails). */
export function Audit() {
  const [tab, setTab] = useState<Tab>("scans");
  const [scans, setScans] = useState<ScanRow[]>([]);
  const [threshold, setThreshold] = useState(3);
  const [mailLogs, setMailLogs] = useState<MailLogRow[]>([]);
  const [reportLogs, setReportLogs] = useState<ReportLogRow[]>([]);
  const [requests, setRequests] = useState<ReportRequestRow[]>([]);
  const [error, setError] = useState<string | null>(null);

  const monthRange = useMemo(currentMonthRange, []);

  useEffect(() => {
    let active = true;
    const load = async () => {
      try {
        const [settings, s] = await Promise.all([
          loadSettings(),
          loadScansBetween(monthRange.start, monthRange.end),
        ]);
        if (!active) return;
        setThreshold(settings.escalationThreshold);
        setScans(s);
      } catch {
        if (active) setError("Couldn\u2019t load the audit log. Check the network and try again.");
      }
    };
    void load();
    return () => {
      active = false;
    };
  }, [monthRange]);

  useEffect(() => {
    let active = true;
    Promise.all([loadMailLogs(), fetchReportLogs(), loadReportRequests()])
      .then(([mail, repLogs, reqs]) => {
        if (!active) return;
        setMailLogs(mail);
        setReportLogs(repLogs);
        setRequests(reqs);
      })
      .catch(() => {
        if (active) setError("Couldn\u2019t load the audit log. Check the network and try again.");
      });
    return () => {
      active = false;
    };
  }, []);

  const countsByStudent = useMemo(() => {
    const counts = new Map<string, number>();
    for (const r of scans) counts.set(r.studentId, (counts.get(r.studentId) ?? 0) + 1);
    return counts;
  }, [scans]);

  return (
    <div>
      <SectionTitle
        title="Audit log"
        subtitle="Every scan records who, what student, and when - plus the mail and report trails."
      />

      <div className="flex flex-wrap gap-2">
        {TABS.map((t) => (
          <button
            key={t.value}
            type="button"
            onClick={() => setTab(t.value)}
            className={`rounded-md border px-4 py-2 text-sm font-semibold ${
              tab === t.value
                ? "border-maroon-900 bg-maroon-900 text-white"
                : "border-sand-200 bg-white text-navy-900 hover:bg-sand-200"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="mt-4">
        {error ? <EmptyState>{error}</EmptyState> : null}

        {tab === "scans" ? (
          <Card>
            <p className="border-b border-sand-200 px-4 py-3 text-xs text-ink-900/60">
              This month
            </p>
            {scans.length === 0 ? (
              <EmptyState>No late scans this month.</EmptyState>
            ) : (
              <DataTable
                keyOf={(r) => r.logId}
                columns={[
                  { label: "Date", className: "tabular whitespace-nowrap", render: (r) => dayKey(r.scanTimestamp) },
                  { label: "Time", className: "tabular whitespace-nowrap", render: (r) => r.time },
                  { label: "Student ID", className: "tabular whitespace-nowrap", render: (r) => r.studentId },
                  { label: "Name", render: (r) => r.name },
                  { label: "Department", render: (r) => r.department || "\u2014" },
                  {
                    label: "Month count",
                    render: (r) => <StatusBadge count={countsByStudent.get(r.studentId) ?? 0} threshold={threshold} />,
                  },
                  { label: "Scanned by", render: (r) => r.scannedByName },
                  {
                    label: "Source",
                    render: (r) => (r.syncedOffline ? "Synced from offline" : "Online scan"),
                  },
                ]}
                rows={scans}
              />
            )}
          </Card>
        ) : null}

        {tab === "mail" ? (
          <Card>
            {mailLogs.length === 0 ? (
              <EmptyState>No escalation mail has been sent yet.</EmptyState>
            ) : (
              <DataTable
                keyOf={(r) => r.id}
                columns={[
                  { label: "Sent", render: (r) => (r.sentTimestamp ? dayKey(r.sentTimestamp) : "\u2014") },
                  { label: "Department", render: (r) => r.department },
                  { label: "Recipient", className: "tabular whitespace-nowrap", render: (r) => r.to },
                  { label: "Subject", render: (r) => r.subject },
                  { label: "Students", className: "tabular", render: (r) => String(r.studentsIncluded.length) },
                ]}
                rows={mailLogs}
              />
            )}
          </Card>
        ) : null}

        {tab === "reports" ? (
          <div className="space-y-5">
            <div>
              <h2 className="mb-2 text-sm font-semibold text-navy-900">Generated reports</h2>
              <Card>
                {reportLogs.length === 0 ? (
                  <EmptyState>No reports generated yet.</EmptyState>
                ) : (
                  <DataTable
                    keyOf={(r) => r.reportId}
                    columns={[
                      { label: "Report", render: (r) => r.label },
                      { label: "Department", render: (r) => r.department ?? "All" },
                      { label: "Year", render: (r) => r.year ?? "All" },
                      { label: "Entries", className: "tabular", render: (r) => `${r.totalLateEntries} / ${r.distinctStudents}` },
                      { label: "Generated", render: (r) => (r.generatedAt ? dayKey(r.generatedAt) : "\u2014") },
                    ]}
                    rows={reportLogs}
                  />
                )}
              </Card>
            </div>
            <div>
              <h2 className="mb-2 text-sm font-semibold text-navy-900">Pending requests</h2>
              <Card>
                {requests.length === 0 ? (
                  <EmptyState>No report requests yet.</EmptyState>
                ) : (
                  <DataTable
                    keyOf={(r) => r.id}
                    columns={[
                      { label: "Status", render: (r) => r.status },
                      { label: "Period type", render: (r) => r.periodType },
                      { label: "Start", className: "tabular whitespace-nowrap", render: (r) => r.startDate },
                      { label: "End", className: "tabular whitespace-nowrap", render: (r) => r.endDate },
                      { label: "Department", render: (r) => r.department ?? "All" },
                      { label: "Year", render: (r) => r.year ?? "All" },
                    ]}
                    rows={requests}
                  />
                )}
              </Card>
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
}