import { useEffect, useRef, useState } from "react";
import { useAuth } from "../auth/AuthContext";
import {
  loadDepartments,
  loadReportRequests,
  loadScansBetween,
  fetchReportLogs,
} from "../lib/firestore";
import type { ReportLogRow, ReportRequestRow, ScanRow } from "../lib/firestore";
import { requestReport } from "../lib/reportService";
import {
  filterRows,
  reportWindowFor,
  summarizeReport,
  utcRangeForWindow,
  windowLabel,
} from "../lib/report";
import type { Department, ReportPeriodType, ReportSummary } from "../lib/report";
import { Card, DataTable, EmptyState, Notice, PrimaryButton, SectionTitle, selectClass, inputClass, Spinner } from "../components/Ui";

const PERIODS: { value: ReportPeriodType; label: string }[] = [
  { value: "daily", label: "Daily" },
  { value: "weekly", label: "Weekly" },
  { value: "monthly", label: "Monthly" },
  { value: "custom", label: "Custom" },
];

function parseDay(value: string): Date {
  const [y, m, d] = value.split("-").map(Number);
  return new Date(y, (m ?? 1) - 1, d ?? 1);
}

export function Reports() {
  const { user, role } = useAuth();
  const [periodType, setPeriodType] = useState<ReportPeriodType>("daily");
  const [anchor, setAnchor] = useState(() => new Date());
  const [customStart, setCustomStart] = useState(() => new Date());
  const [customEnd, setCustomEnd] = useState(() => new Date());
  const [dept, setDept] = useState<string>("");
  const [year, setYear] = useState<string>("");
  const [departments, setDepartments] = useState<Department[]>([]);
  const [years, setYears] = useState<string[]>([]);
  const [preview, setPreview] = useState<ReportSummary | null>(null);
  const [previewBusy, setPreviewBusy] = useState(true);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [exportBusy, setExportBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [requests, setRequests] = useState<ReportRequestRow[]>([]);
  const [logs, setLogs] = useState<ReportLogRow[]>([]);
  // Last fetched scan rows (B6): dept/year clicks refilter these locally
  // instead of round-tripping the same range query to Firestore.
  const scanRowsRef = useRef<ScanRow[]>([]);
  const [rowsVersion, setRowsVersion] = useState(0);

  const canRequest = user !== null && (role === "pt_sir" || role === "admin");
  const requestedBy = user?.uid ?? "";

  const window = reportWindowFor(periodType, anchor, customStart, customEnd);
  const range = utcRangeForWindow(window);
  const selectedDept: Department | null = departments.find((d) => d.id === dept) ?? null;
  const rangeKey = `${range.start.getTime()}-${range.end.getTime()}`;

  useEffect(() => {
    let active = true;
    loadDepartments()
      .then((depts) => {
        if (active) setDepartments(depts);
      })
      .catch(() => {
        if (active) setError("Couldn\u2019t load report filters. Check the network and try again.");
      });
    return () => {
      active = false;
    };
  }, []);

  // Data pass: ONE fetch per range change (this used to be two — a years
  // pass and a preview pass — plus a redundant refetch on every department or
  // year click even though those only filter locally).
  useEffect(() => {
    let active = true;
    setPreviewBusy(true);
    setPreviewError(null);
    loadScansBetween(range.start, range.end)
      .then((rows) => {
        if (!active) return;
        scanRowsRef.current = rows;
        const seen = new Set<string>();
        for (const r of rows) if (r.year) seen.add(r.year);
        setYears([...seen].sort());
        setRowsVersion((v) => v + 1);
      })
      .catch(() => {
        if (active) setPreviewError("Couldn\u2019t load the preview. Check the network and try again.");
      })
      .finally(() => {
        if (active) setPreviewBusy(false);
      });
    return () => {
      active = false;
    };
  }, [rangeKey]);

  // Local pass: department/year clicks refilter the cached rows instantly —
  // zero network (B6). rowsVersion re-derives once a new range arrives.
  useEffect(() => {
    if (rowsVersion === 0) return;
    setPreview(
      summarizeReport(filterRows(scanRowsRef.current, selectedDept, year || null, departments))
    );
  }, [dept, year, departments, rowsVersion]);

  useEffect(() => {
    let active = true;
    Promise.all([loadReportRequests(), fetchReportLogs()])
      .then(([reqs, logRows]) => {
        if (!active) return;
        setRequests(reqs);
        setLogs(logRows);
      })
      .catch(() => {
        if (active) setError("Couldn\u2019t load past reports. Check the network and try again.");
      });
    return () => {
      active = false;
    };
  }, []);

  async function exportReport() {
    if (exportBusy || !canRequest) return;
    setExportBusy(true);
    setNotice(null);
    setError(null);
    try {
      const message = await requestReport({
        filters: {
          periodType,
          startDate: window.start,
          endDate: window.end,
          department: selectedDept,
          year: year || null,
        },
        requestedBy,
      });
      setNotice(message);
      const [reqs, logRows] = await Promise.all([loadReportRequests(), fetchReportLogs()]);
      setRequests(reqs);
      setLogs(logRows);
    } catch {
      setError("The report couldn\u2019t be requested \u2014 check the network and try again.");
    } finally {
      setExportBusy(false);
    }
  }

  const iso = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

  return (
    <div>
      <SectionTitle
        title="Reports"
        subtitle="Preview any period here; the Excel and PDF are prepared by the office."
      />

      <Card className="p-5">
        <p className="mb-3 text-sm font-semibold text-navy-900">Report period</p>
        <div className="flex flex-wrap gap-2">
          {PERIODS.map((p) => (
            <button
              key={p.value}
              type="button"
              onClick={() => setPeriodType(p.value)}
              className={`rounded-md border px-4 py-2 text-sm font-semibold ${
                periodType === p.value
                  ? "border-maroon-900 bg-maroon-900 text-white"
                  : "border-sand-200 bg-white text-navy-900 hover:bg-sand-200"
              }`}
            >
              {p.label}
            </button>
          ))}
        </div>

        <div className="mt-4 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {(periodType === "daily" || periodType === "weekly") && (
            <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
              {periodType === "daily" ? "Report date" : "Week starting"}
              <input
                className={inputClass}
                type="date"
                value={iso(anchor)}
                onChange={(e) => setAnchor(parseDay(e.target.value) || anchor)}
              />
            </label>
          )}
          {periodType === "monthly" && (
            <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
              Month
              <input
                className={inputClass}
                type="month"
                value={iso(anchor).slice(0, 7)}
                onChange={(e) => setAnchor(e.target.value ? parseDay(`${e.target.value}-01`) : anchor)}
              />
            </label>
          )}
          {periodType === "custom" && (
            <>
              <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
                From
                <input
                  className={inputClass}
                  type="date"
                  value={iso(customStart)}
                  onChange={(e) => setCustomStart(parseDay(e.target.value) || customStart)}
                />
              </label>
              <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
                To
                <input
                  className={inputClass}
                  type="date"
                  value={iso(customEnd)}
                  onChange={(e) => setCustomEnd(parseDay(e.target.value) || customEnd)}
                />
              </label>
            </>
          )}
          <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
            Department
            <select className={selectClass} value={dept} onChange={(e) => setDept(e.target.value)}>
              <option value="">All departments</option>
              {departments.map((d) => (
                <option key={d.id} value={d.id}>
                  {d.name}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1.5 text-sm text-ink-900/70">
            Year
            <select className={selectClass} value={year} onChange={(e) => setYear(e.target.value)}>
              <option value="">All years</option>
              {years.map((y) => (
                <option key={y} value={y}>
                  {y}
                </option>
              ))}
            </select>
          </label>
        </div>

        <div className="mt-5 border-t border-sand-200 pt-4">
          <p className="mb-2 text-sm font-semibold text-navy-900">Preview</p>
          {previewBusy ? (
            <div className="flex justify-center py-8">
              <Spinner />
            </div>
          ) : previewError ? (
            <p className="py-4 text-sm text-status-escalate">{previewError}</p>
          ) : (
            <div>
              <p className="text-sm text-ink-900/60">{windowLabel(window, periodType)}</p>
              <div className="mt-2 flex flex-wrap items-baseline gap-x-6 gap-y-1">
                <p className="tabular text-3xl font-bold text-maroon-700">{preview?.totalLateEntries ?? 0}</p>
                <p className="text-sm text-ink-900/70">
                  {(preview?.totalLateEntries ?? 0) === 1 ? "late entry" : "late entries"}
                </p>
                <p className="text-sm text-ink-900/70">
                  {(preview?.distinctStudents ?? 0)}{" "}
                  {(preview?.distinctStudents ?? 0) === 1 ? "student" : "students"}
                </p>
              </div>
              {preview && preview.byDepartment.length > 0 ? (
                <div className="mt-3 grid max-w-xl gap-x-8 gap-y-1 sm:grid-cols-2">
                  {preview.byDepartment.map((d) => (
                    <p key={d.department} className="flex justify-between border-b border-sand-200/70 py-1 text-sm">
                      <span>{d.department}</span>
                      <span className="tabular font-semibold text-maroon-700">{d.count}</span>
                    </p>
                  ))}
                </div>
              ) : null}
            </div>
          )}
        </div>

        <div className="mt-5 flex flex-col gap-2 border-t border-sand-200 pt-4">
          {!canRequest ? (
            <p className="text-sm text-ink-900/70">
              Reports can only be generated by the gate office (PT sir / admin).
            </p>
          ) : null}
          <div className="flex flex-wrap items-center gap-4">
            {canRequest ? (
              <PrimaryButton onClick={exportReport} disabled={!canRequest} busy={exportBusy}>
                Generate Excel &amp; PDF
              </PrimaryButton>
            ) : null}
            {notice ? <Notice>{notice}</Notice> : null}
            {error ? <Notice kind="error">{error}</Notice> : null}
          </div>
        </div>
      </Card>

      <h2 className="mb-3 mt-8 text-base font-semibold text-navy-900">Generated reports</h2>
      <Card>
        {logs.length === 0 ? (
          <EmptyState>No reports have been generated yet.</EmptyState>
        ) : (
          <DataTable
            keyOf={(r) => r.reportId}
            columns={[
              { label: "Report", render: (r) => r.label },
              { label: "Department", render: (r) => r.department ?? "All" },
              { label: "Year", render: (r) => r.year ?? "All" },
              { label: "Entries", className: "tabular", render: (r) => `${r.totalLateEntries} / ${r.distinctStudents}` },
              { label: "Files", className: "tabular", render: (r) => r.files.map((f) => f.name).join(", ") },
            ]}
            rows={logs}
          />
        )}
      </Card>

      <h2 className="mb-3 mt-8 text-base font-semibold text-navy-900">Requests</h2>
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
  );
}