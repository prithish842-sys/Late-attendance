import { describe, it, expect } from "vitest";
import {
  reportWindowFor,
  dayKey,
  formatTime,
  utcRangeForWindow,
  todayLocalRange,
  displayToken,
  findDepartment,
  filterRows,
  summarizeReport,
  lateCountLevel,
  countLabel,
} from "./report";

const d = (y: number, m: number, day: number) => new Date(y, m - 1, day);

describe("reportWindowFor", () => {
  it("daily covers the anchor day", () => {
    const w = reportWindowFor("daily", d(2026, 9, 24));
    expect(w.start).toEqual(d(2026, 9, 24));
    expect(w.end).toEqual(d(2026, 9, 24));
  });

  it("weekly starts on Monday", () => {
    // 2026-09-24 is a Thursday.
    const w = reportWindowFor("weekly", d(2026, 9, 24));
    expect(w.start).toEqual(d(2026, 9, 21));
    expect(w.end).toEqual(d(2026, 9, 27));
  });

  it("monthly spans the calendar month", () => {
    const w = reportWindowFor("monthly", d(2026, 9, 24));
    expect(w.start).toEqual(d(2026, 9, 1));
    expect(w.end).toEqual(d(2026, 9, 30));
  });

  it("custom clamps an inverted range", () => {
    const w = reportWindowFor("custom", d(2026, 9, 24), d(2026, 9, 30), d(2026, 9, 1));
    expect(w.start).toEqual(d(2026, 9, 1));
    expect(w.end).toEqual(d(2026, 9, 30));
  });
});

describe("dayKey / utcRangeForWindow", () => {
  it("formats a padded YYYY-MM-DD key", () => {
    expect(dayKey(d(2026, 9, 5))).toBe("2026-09-05");
  });

  it("turns a local day window into UTC boundaries matching the server", () => {
    const w = reportWindowFor("daily", d(2026, 9, 24));
    const range = utcRangeForWindow(w);
    expect(range.start).toEqual(new Date(Date.UTC(2026, 8, 24)));
    expect(range.end).toEqual(new Date(Date.UTC(2026, 8, 25)));
  });

  it("todayLocalRange is a local midnight-to-midnight window", () => {
    const range = todayLocalRange();
    expect(range.start.getHours()).toBe(0);
    expect(range.start.getMinutes()).toBe(0);
    expect(range.end.getTime() - range.start.getTime()).toBe(86_400_000);
  });
});

describe("formatTime", () => {
  it("pads hour and minute", () => {
    expect(formatTime(new Date(2026, 8, 24, 9, 5))).toBe("09:05");
  });
});

describe("displayToken / findDepartment", () => {
  const departments = [{ id: "BSC-CS", name: "B.Sc Computer Science" }];

  it("normalizes to alphanumerics for fuzzy matching", () => {
    expect(displayToken("B.SC CS")).toBe("bsccs");
    expect(displayToken("BSC-CS")).toBe("bsccs");
  });

  it("resolves a display string to the reference doc id", () => {
    const match = findDepartment(departments, "B.SC CS");
    expect(match?.id).toBe("BSC-CS");
  });

  it("returns null for an unknown department", () => {
    expect(findDepartment(departments, "Unknown")).toBeNull();
  });
});

describe("filterRows", () => {
  const departments = [{ id: "BSC-CS", name: "B.Sc Computer Science" }];
  const rows = [
    { studentId: "S1", name: "A", department: "B.SC CS", year: "2026" },
    { studentId: "S2", name: "B", department: "BSC-CS", year: "2025" },
    { studentId: "S3", name: "C", department: "M.Com", year: "2026" },
  ];

  it("filters by fuzzy department match", () => {
    const out = filterRows(rows, { id: "BSC-CS", name: "B.Sc Computer Science" }, null, departments);
    expect(out.map((r) => r.studentId)).toEqual(["S1", "S2"]);
  });

  it("filters by exact year token", () => {
    const out = filterRows(rows, null, "2026", departments);
    expect(out.map((r) => r.studentId)).toEqual(["S1", "S3"]);
  });
});

describe("summarizeReport", () => {
  it("aggregates totals and sorts departments by count then name", () => {
    const summary = summarizeReport([
      { studentId: "S1", department: "B.SC CS" },
      { studentId: "S1", department: "B.SC CS" },
      { studentId: "S2", department: "B.SC CS" },
      { studentId: "S3", department: "" },
    ]);
    expect(summary.totalLateEntries).toBe(4);
    expect(summary.distinctStudents).toBe(3);
    expect(summary.byDepartment[0]).toEqual({ department: "B.SC CS", count: 3 });
    expect(summary.byDepartment[1]).toEqual({ department: "Unassigned", count: 1 });
  });
});

describe("lateCountLevel / countLabel", () => {
  it("mirrors computeEscalation severity", () => {
    expect(lateCountLevel(1, 3)).toBe("ok");
    expect(lateCountLevel(2, 3)).toBe("warn");
    expect(lateCountLevel(3, 3)).toBe("escalate");
    expect(lateCountLevel(2, 2)).toBe("escalate");
  });

  it("always pairs severity with explicit count text", () => {
    expect(countLabel(2)).toBe("2nd time this month");
    expect(countLabel(11)).toBe("11th time this month");
    expect(countLabel(0)).toBe("No lates this month");
  });
});