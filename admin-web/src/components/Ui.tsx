import type { ReactNode } from "react";

export const inputClass =
  "w-full rounded-md border border-sand-200 bg-white px-3 py-2 text-sm text-ink-900 focus:border-maroon-700 focus:outline-none";

export const selectClass = inputClass;

export function Card({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <div className={`rounded-md border border-sand-200 bg-white ${className}`}>{children}</div>;
}

export function SectionTitle({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <div className="mb-5">
      <h1 className="text-xl font-semibold text-navy-900">{title}</h1>
      {subtitle ? <p className="mt-1 text-sm text-ink-900/70">{subtitle}</p> : null}
    </div>
  );
}

export function PrimaryButton({
  children,
  onClick,
  disabled,
  busy,
  type = "button",
}: {
  children: ReactNode;
  onClick?: () => void;
  disabled?: boolean;
  busy?: boolean;
  type?: "button" | "submit";
}) {
  return (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled || busy}
      className="inline-flex h-11 items-center justify-center rounded-md bg-maroon-900 px-6 text-base font-semibold text-white hover:bg-maroon-700 disabled:bg-sand-200 disabled:text-ink-900/60"
    >
      {busy ? <Spinner /> : children}
    </button>
  );
}

export function Spinner() {
  return (
    <span
      aria-label="Loading"
      className="inline-block h-5 w-5 animate-spin rounded-full border-2 border-sand-200 border-t-maroon-900"
    />
  );
}

export function Notice({ kind = "success", children }: { kind?: "success" | "error"; children: ReactNode }) {
  const className =
    kind === "error"
      ? "border-status-escalate/30 bg-status-escalate/5 text-status-escalate"
      : "border-status-ok/30 bg-status-ok/5 text-status-ok";
  return <p className={`rounded-md border px-3 py-2 text-sm ${className}`}>{children}</p>;
}

export function EmptyState({ children }: { children: ReactNode }) {
  return <p className="px-4 py-8 text-center text-sm text-ink-900/70">{children}</p>;
}

/** Dense table with tabular numerals (DESIGN.md §3 - tables stay tables). */
export function DataTable<T>({
  columns,
  rows,
  keyOf,
}: {
  columns: { label: string; render: (row: T) => ReactNode; className?: string }[];
  rows: T[];
  keyOf: (row: T) => string;
}) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left text-sm">
        <thead>
          <tr className="border-b border-sand-200 text-xs font-semibold text-ink-900/60">
            {columns.map((c) => (
              <th key={c.label} className={`px-3 py-2 font-semibold ${c.className ?? ""}`}>
                {c.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={keyOf(row)} className="border-b border-sand-200/70 last:border-b-0">
              {columns.map((c) => (
                <td key={c.label} className={`px-3 py-2 align-top ${c.className ?? ""}`}>
                  {c.render(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}