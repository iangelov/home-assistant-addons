import assert from "node:assert/strict";
import test from "node:test";
import { checkVersion } from "../scripts/check-version.mjs";

const config = (version) => `name: Tailscale\nversion: "${version}"\n`;

test("an explicit bump publishes independently of the upstream version", () => {
  assert.deepEqual(checkVersion(config("v1.104.2"), config("2.0.0"), ["tailscale/config.yaml"]),
    { version: "2.0.0", publish: true });
});

test("runtime changes without a bump fail", () => {
  for (const path of ["tailscale/Dockerfile", "tailscale/run.sh", "tailscale/files/install.sh", "tailscale/config.yaml"]) {
    assert.throws(() => checkVersion(config("2.0.0"), config("2.0.0"), [path]), /bump/i);
  }
});

test("documentation, icons, and CI changes do not publish", () => {
  assert.deepEqual(checkVersion(config("2.0.0"), config("2.0.0"),
    ["README.md", "tailscale/DOCS.md", "tailscale/icon.png", ".github/workflows/builder.yaml"]),
    { version: "2.0.0", publish: false });
});

test("compares versions numerically and rejects downgrades or malformed versions", () => {
  assert.equal(checkVersion(config("2.9.0"), config("2.10.0"), []).publish, true);
  for (const version of ["1.9.9", "v2.1.0", "2.01.0", "2.1", "2.1.0-rc.1"]) {
    assert.throws(() => checkVersion(config("2.0.0"), config(version), []), /version|SemVer/);
  }
  assert.throws(() => checkVersion(config("2.0.0"), 'name: Tailscale\n', []), /version/);
});
