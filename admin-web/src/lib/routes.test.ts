import { describe, expect, it } from "vitest";
import { canOpenSettings } from "./routes";

describe("route access (V2)", () => {
  it("opens Settings for admins only", () => {
    expect(canOpenSettings("admin")).toBe(true);
  });

  it("redirects pt_sir, anonymous and unknown roles", () => {
    expect(canOpenSettings("pt_sir")).toBe(false);
    expect(canOpenSettings(null)).toBe(false);
    expect(canOpenSettings("hod")).toBe(false);
  });
});
