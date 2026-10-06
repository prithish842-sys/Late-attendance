import { describe, it, expect } from "vitest";
import { describeAuthError, signInFailure } from "./describeAuthError";

describe("describeAuthError", () => {
  it("describes an invalid email", () => {
    expect(describeAuthError({ code: "auth/invalid-email" })).toContain("valid email address");
  });

  it("groups the legacy + modern wrong-credential codes together", () => {
    for (const code of ["auth/user-not-found", "auth/invalid-credential", "auth/wrong-password", "auth/invalid-login-credentials"]) {
      expect(describeAuthError({ code })).toContain("isn\u2019t right");
    }
  });

  it("gives plain-language action for rate limiting", () => {
    expect(describeAuthError({ code: "auth/too-many-requests" })).toContain("Wait a minute");
  });

  it("has a safe default for unknown errors", () => {
    expect(describeAuthError("something exploded")).toContain("Sign-in failed");
    expect(describeAuthError(null)).toContain("Sign-in failed");
  });

  it("counts credential errors toward the login ledger", () => {
    for (const code of ["auth/invalid-credential", "auth/wrong-password", "auth/user-not-found"]) {
      expect(signInFailure({ code }).countsAsFailure).toBe(true);
    }
  });

  it("does NOT count network failures or Firebase's own throttle", () => {
    expect(signInFailure({ code: "auth/network-request-failed" }).countsAsFailure).toBe(false);
    expect(signInFailure({ code: "auth/too-many-requests" }).countsAsFailure).toBe(false);
    expect(signInFailure({ code: "auth/network-request-failed" }).message).toContain("network");
  });
});