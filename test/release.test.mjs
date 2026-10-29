import assert from "node:assert/strict";
import test from "node:test";
import { createRelease } from "../scripts/create-release.mjs";

const sha = "a".repeat(40);
const repo = "iangelov/home-assistant-addons";
const missing = () => { throw Object.assign(new Error("Not Found"), { stderr: "gh: Not Found (HTTP 404)" }); };

test("creates the release at the built commit after publication", () => {
  const writes = [];
  createRelease("2.0.0", sha, repo, (command, args) => {
    assert.equal(command, "gh");
    if (args[0] === "api") {
      if (args[1].includes("/commits/")) {
        throw Object.assign(new Error("No commit found for SHA"), {
          stderr: "gh: No commit found for SHA: tailscale-v2.0.0 (HTTP 422)",
        });
      }
      return missing();
    }
    writes.push(args);
    return "";
  });
  assert.deepEqual(writes, [["release", "create", "tailscale-v2.0.0", "--repo", repo,
    "--target", sha, "--generate-notes", "--title", "tailscale-v2.0.0"]]);
});

test("a retry preserves an existing release for this commit", () => {
  createRelease("2.0.0", sha, repo, (_command, args) => {
    assert.equal(args[0], "api", "a completed release must not be written again");
    return JSON.stringify(args[1].includes("/commits/") ? { sha } : { id: 123 });
  });
});

test("a tag pointing elsewhere prevents release creation", () => {
  assert.throws(() => createRelease("2.0.0", sha, repo, () => JSON.stringify({ sha: "b".repeat(40) })), /another commit/);
});

test("an API failure is not mistaken for a missing release", () => {
  assert.throws(() => createRelease("2.0.0", sha, repo, () => {
    throw Object.assign(new Error("Forbidden"), { stderr: "gh: Forbidden (HTTP 403)" });
  }), /Forbidden/);
});
