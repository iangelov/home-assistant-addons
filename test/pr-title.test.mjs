import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";

function validate(title) {
  return spawnSync(process.execPath, ["scripts/validate-pr-title.mjs"], {
    cwd: process.cwd(),
    encoding: "utf8",
    env: { ...process.env, PR_TITLE: title },
  });
}

test("accepts release-bearing Tailscale PR titles", () => {
  for (const title of [
    "fix(tailscale): update Tailscale to v1.104.0",
    "feat(tailscale): add an optional proxy",
    "feat(tailscale)!: adopt independent versioning",
  ]) {
    assert.equal(validate(title).status, 0, title);
  }
});

test("accepts non-release repository maintenance titles", () => {
  for (const title of [
    "chore(ci): update semantic-release",
    "docs(tailscale): document authentication",
    "test(tailscale): cover advertised routes",
  ]) {
    assert.equal(validate(title).status, 0, title);
  }
});

test("rejects titles whose release intent is ambiguous", () => {
  for (const title of [
    "Update Tailscale",
    "[semver:minor] add an optional proxy",
    "feat: add an optional proxy",
    "feature(tailscale): add an optional proxy",
  ]) {
    const result = validate(title);
    assert.notEqual(result.status, 0, title);
    assert.match(result.stderr, /Conventional Commit/);
  }
});
