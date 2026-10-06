import { countLabel, lateCountLevel } from "../lib/report";

const COLORS: Record<string, string> = {
  ok: "#2E7D4F",
  warn: "#C77A1F",
  escalate: "#8B1E1E",
};

/** Late-count severity badge - color is never the only signal (DESIGN.md §6). */
export function StatusBadge({ count, threshold }: { count: number; threshold: number }) {
  const level = lateCountLevel(count, threshold);
  const color = COLORS[level];
  return (
    <span
      className="inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-semibold"
      style={{ color, backgroundColor: `${color}1a` }}
    >
      <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full" style={{ backgroundColor: color }} />
      {countLabel(count)}
    </span>
  );
}