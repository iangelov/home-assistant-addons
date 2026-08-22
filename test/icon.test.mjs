import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships a square PNG icon for the Home Assistant app list", async () => {
  const icon = await readFile("tailscale/icon.png");
  assert.equal(icon.subarray(1, 4).toString(), "PNG");
  assert.equal(icon.readUInt32BE(16), icon.readUInt32BE(20));
});
