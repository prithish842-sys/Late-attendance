/**
 * How the admin web app requests a report (docs/NOTES.md "Blaze switch").
 * Mirrors the Flutter ReportService: the report is always server-authoritative;
 * the web app only expresses intent.
 *
 *   - Spark (VITE_BLAZE_ENABLED=false, default): a report_requests doc is
 *     created (the only client-writable Phase-4 path, firestore.rules). The
 *     Admin-SDK runner (scripts/generate-report.js) consumes the queue and
 *     writes the Excel/PDF to the office machine.
 *   - Blaze (VITE_BLAZE_ENABLED=true): calls the generateReport HttpsCallable
 *     directly - same guard rails (role pt_sir/admin) enforced server-side,
 *     files stored in Cloud Storage with signed URLs returned.
 */
import { doc, setDoc, serverTimestamp } from "firebase/firestore";
import { getFunctions, httpsCallable } from "firebase/functions";
import { isBlazeEnabled } from "../config";
import { db } from "../fb";
import { dayKey, type ReportFilters } from "./report";

export async function requestReport({
  filters,
  requestedBy,
}: {
  filters: ReportFilters;
  requestedBy: string;
}): Promise<string> {
  if (isBlazeEnabled()) {
    const callable = httpsCallable<unknown, unknown>(getFunctions(), "generateReport");
    const res = await callable.call({
      periodType: filters.periodType,
      startDate: dayKey(filters.startDate),
      endDate: dayKey(filters.endDate),
      department: filters.department?.id ?? null,
      year: filters.year ?? null,
    });
    const map = (res.data ?? {}) as Record<string, unknown>;
    const stats = (map.stats ?? {}) as Record<string, unknown>;
    const total = typeof stats.totalLateEntries === "number" ? stats.totalLateEntries : null;
    return total == null
      ? "Report generated."
      : `Report generated - ${total} late ${total === 1 ? "entry" : "entries"}.`;
  }

  const id = `report_${Date.now().toString(36)}`;
  await setDoc(doc(db, "report_requests", id), {
    periodType: filters.periodType,
    startDate: dayKey(filters.startDate),
    endDate: dayKey(filters.endDate),
    department: filters.department?.id ?? null,
    year: filters.year ?? null,
    requestedBy,
    status: "pending",
    attemptCount: 0,
    requestedAt: serverTimestamp(),
  });
  return "Report requested - the office will generate the Excel and PDF files.";
}