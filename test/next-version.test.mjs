import assert from "node:assert/strict";
import test from "node:test";
import { nextVersion } from "../scripts/next-version.mjs";

test("maps Tailscale PR cues to patch, minor, and major releases", () => {
  assert.equal(nextVersion("2.0.0", ["fix(tailscale): repair startup"]), "2.0.1");
  assert.equal(nextVersion("2.0.0", ["feat(tailscale): add a web client"]), "2.1.0");
  assert.equal(
    nextVersion("1.102.3", ["feat(tailscale)!: adopt independent versioning"]),
    "2.0.0",
  );
});

test("recognizes a BREAKING CHANGE footer", () => {
  assert.equal(
    nextVersion("2.4.1", [
      "feat(tailscale): change authentication\n\nBREAKING CHANGE: existing keys must be recreated",
    ]),
    "3.0.0",
  );
});

test("does not release Tailscale for unrelated or maintenance commits", () => {
  assert.equal(nextVersion("2.0.0", ["feat(other-addon): add a feature"]), null);
  assert.equal(nextVersion("2.0.0", ["chore(tailscale): update release tooling"]), null);
  assert.equal(nextVersion("2.0.0", ["docs(tailscale): improve the readme"]), null);
});

test("chooses the highest release required by a batch of commits", () => {
  assert.equal(
    nextVersion("2.3.4", [
      "fix(tailscale): repair startup",
      "feat(tailscale): add a web client",
    ]),
    "2.4.0",
  );
});

test("rejects a malformed current version", () => {
  assert.throws(() => nextVersion("v2.0.0", ["fix(tailscale): repair startup"]), /SemVer/);
});
