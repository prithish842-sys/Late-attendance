import { describe, expect, it } from "vitest";
import {
  LOGIN_MAX_ATTEMPTS,
  LOGIN_WINDOW_MS,
  lockMessage,
  lockedRemainingMs,
  pruneFailures,
  recordFailure,
} from "./loginThrottle";

const T0 = 1_800_000_000_000; // fixed epoch base

describe("loginThrottle (C1)", () => {
  it("uses the agreed 5 attempts / 15 minutes policy", () => {
    expect(LOGIN_MAX_ATTEMPTS).toBe(5);
    expect(LOGIN_WINDOW_MS).toBe(15 * 60 * 1000);
  });

  it("allows sign-in below the cap and locks at the 5th failure", () => {
    let failures: number[] = [];
    for (let i = 0; i < 4; i++) {
      failures = recordFailure(failures, T0);
      expect(lockedRemainingMs(failures, T0)).toBe(0);
    }
    failures = recordFailure(failures, T0);
    expect(lockedRemainingMs(failures, T0)).toBe(LOGIN_WINDOW_MS);
  });

  it("auto-releases once the oldest failure ages out and keeps the rest", () => {
    // Staggered attempts — one per minute — so only the oldest expires first.
    let failures: number[] = [];
    for (let i = 0; i < 5; i++) failures = recordFailure(failures, T0 + i * 60_000);

    const inside = T0 + 14 * 60_000;
    expect(lockedRemainingMs(failures, inside)).toBeGreaterThan(0);

    const after = T0 + 15 * 60_000 + 1;
    expect(lockedRemainingMs(failures, after)).toBe(0);
    expect(pruneFailures(failures, after).length).toBe(4);
  });

  it("stale failures never count toward the lock", () => {
    const ancient = T0 - LOGIN_WINDOW_MS - 1;
    const failures = [ancient, ancient, ancient, ancient, ancient];
    expect(lockedRemainingMs(failures, T0)).toBe(0);
  });

  it("messages stay plain-language and round up to whole minutes", () => {
    expect(lockMessage(LOGIN_WINDOW_MS)).toBe(
      "Too many failed sign-in attempts — try again in 15 minutes."
    );
    expect(lockMessage(30_000)).toBe(
      "Too many failed sign-in attempts — try again in a moment."
    );
    expect(lockMessage(80_000)).toBe(
      "Too many failed sign-in attempts — try again in 2 minutes."
    );
  });
});
