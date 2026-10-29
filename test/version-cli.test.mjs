import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const script = resolve("scripts/check-version.mjs");
test("the workflow command compares Git revisions and emits release outputs", (t) => {
  const cwd = mkdtempSync(join(tmpdir(), "addon-version-"));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const git = (...args) => execFileSync("git", args, { cwd, encoding: "utf8" });
  git("init", "-q");
  git("config", "user.name", "Test");
  git("config", "user.email", "test@example.com");
  mkdirSync(join(cwd, "tailscale"));
  writeFileSync(join(cwd, "tailscale/config.yaml"), 'version: "2.0.0"\n');
  git("add", ".");
  git("-c", "commit.gpgsign=false", "commit", "-qm", "initial");
  const before = git("rev-parse", "HEAD").trim();
  writeFileSync(join(cwd, "tailscale/config.yaml"), 'version: "2.0.1"\n');
  git("add", ".");
  git("-c", "commit.gpgsign=false", "commit", "-qm", "dependency update");
  const output = join(cwd, "output");
  const result = spawnSync(process.execPath, [script, before, "HEAD"], {
    cwd, encoding: "utf8", env: { ...process.env, GITHUB_OUTPUT: output },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(output, "utf8"), "version=2.0.1\npublish=true\n");
  // The same run must remain reproducible even after main has advanced.
  const released = git("rev-parse", "HEAD").trim();
  writeFileSync(join(cwd, "tailscale/config.yaml"), 'version: "2.0.2"\n');
  git("add", "tailscale");
  git("-c", "commit.gpgsign=false", "commit", "-qm", "later release");
  assert.equal(execFileSync(process.execPath, [script, before, released], {
    cwd, encoding: "utf8", env: { ...process.env, GITHUB_OUTPUT: "" },
  }), "version=2.0.1\npublish=true\n");
});
