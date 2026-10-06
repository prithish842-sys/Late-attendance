import { useEffect, useMemo, useState } from "react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { watchScansBetween } from "../lib/firestore";
import type { ScanRow } from "../lib/firestore";
import { todayLocalRange } from "../lib/report";
import { Card, DataTable, EmptyState, SectionTitle } from "../components/Ui";

const todayLabel = new Intl.DateTimeFormat("en-IN", {
  weekday: "long",
  day: "numeric",
  month: "long",
  year: "numeric",
});

export function Dashboard() {
  const range = useMemo(todayLocalRange, []);
  const [rows, setRows] = useState<ScanRow[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const unsubscribe = watchScansBetween(
      range.start,
      range.end,
      (next) => setRows(next),
      () => setError("Couldn\u2019t load today\u2019s scans. Check the network and try again."),
    );
    return unsubscribe;
  }, [range]);

  const byDepartment = useMemo(() => {
    const counts = new Map<string, number>();
    for (const r of rows) {
      const dep = r.department === "" ? "Unassigned" : r.department;
      counts.set(dep, (counts.get(dep) ?? 0) + 1);
    }
    return [...counts.entries()]
      .map(([department, count]) => ({ department, count }))
      .sort((a, b) => b.count - a.count || a.department.toLowerCase().localeCompare(b.department.toLowerCase()));
  }, [rows]);

  const distinctStudents = useMemo(() => new Set(rows.map((r) => r.studentId)).size, [rows]);

  return (
    <div>
      <SectionTitle title="Dashboard" subtitle={todayLabel.format(new Date())} />

      <div className="grid gap-5 lg:grid-cols-3">
        <Card className="px-6 py-5">
          <p className="text-sm font-medium text-ink-900/70">Today\u2019s late count</p>
          <p className="tabular mt-1 text-5xl font-bold leading-none text-maroon-700">{rows.length}</p>
          <p className="mt-2 text-sm text-ink-900/70">
            {distinctStudents} {distinctStudents === 1 ? "student" : "students"}
          </p>
        </Card>
        <Card className="px-6 py-5 lg:col-span-2">
          <p className="text-sm font-medium text-ink-900/70">By department (today)</p>
          {byDepartment.length === 0 ? (
            <EmptyState>No scans recorded yet today.</EmptyState>
          ) : (
            <div className="h-56">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={byDepartment} margin={{ top: 12, right: 8, left: -16, bottom: 0 }}>
                  <CartesianGrid vertical={false} stroke="#E8E2D8" />
                  <XAxis dataKey="department" tick={{ fontSize: 12, fill: "#232323" }} interval={0} />
                  <YAxis allowDecimals={false} tick={{ fontSize: 12, fill: "#232323" }} />
                  <Tooltip cursor={{ fill: "rgba(0, 0, 0, 0.04)" }} />
                  <Bar dataKey="count" fill="#8B1E1E" radius={[3, 3, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </div>
          )}
        </Card>
      </div>

      <h2 className="mb-3 mt-8 text-base font-semibold text-navy-900">Scanned today</h2>
      <Card>
        {error ? (
          <EmptyState>{error}</EmptyState>
        ) : rows.length === 0 ? (
          <EmptyState>No scans recorded yet today.</EmptyState>
        ) : (
          <DataTable
            keyOf={(r) => r.logId}
            columns={[
              { label: "Time", className: "tabular whitespace-nowrap", render: (r) => r.time },
              { label: "Student ID", className: "tabular whitespace-nowrap", render: (r) => r.studentId },
              { label: "Name", render: (r) => r.name },
              { label: "Department", render: (r) => r.department || "\u2014" },
              { label: "Scanned by", render: (r) => r.scannedByName },
              {
                label: "Flag",
                render: (r) => (r.syncedOffline ? "Synced from offline" : "Online scan"),
              },
            ]}
            rows={rows}
          />
        )}
      </Card>
    </div>
  );
}