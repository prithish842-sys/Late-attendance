/**
 * V2 route access rules (NEW_TASKS Production Hardening).
 *
 * Pure functions so the router and the nav can share one tested source of
 * truth: Settings is ADMIN-ONLY at the router level — non-admins are
 * redirected to the dashboard instead of seeing the read-only editor.
 * (Deliberate product decision: the old PT read-only Settings view was
 * replaced with a route gate for defence in depth.)
 */
export function canOpenSettings(role: string | null): boolean {
  return role === "admin";
}
