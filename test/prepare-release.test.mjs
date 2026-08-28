import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

test("writes the independent add-on version without changing other metadata", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tailscale-release-"));
  const configPath = join(directory, "config.yaml");
  const source = [
    "name: Tailscale",
    'version: "v1.102.3"',
    "slug: tailscale-ha",
    "",
  ].join("\n");
  await writeFile(configPath, source);

  const result = spawnSync(
    process.execPath,
    ["scripts/prepare-release.mjs", "2.0.0", configPath],
    { cwd: process.cwd(), encoding: "utf8" },
  );

  assert.equal(result.status, 0, result.stderr);
  assert.equal(
    await readFile(configPath, "utf8"),
    ["name: Tailscale", 'version: "2.0.0"', "slug: tailscale-ha", ""].join("\n"),
  );
});

test("rejects versions that are not canonical SemVer", async () => {
  const directory = await mkdtemp(join(tmpdir(), "tailscale-release-"));
  const configPath = join(directory, "config.yaml");
  await writeFile(configPath, 'version: "v1.102.3"\n');

  const result = spawnSync(
    process.execPath,
    ["scripts/prepare-release.mjs", "v2.0.0", configPath],
    { cwd: process.cwd(), encoding: "utf8" },
  );

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /canonical SemVer/);
  assert.equal(await readFile(configPath, "utf8"), 'version: "v1.102.3"\n');
});
