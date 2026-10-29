import assert from "node:assert/strict";
import test from "node:test";
import { checkImage, checkManifest } from "../scripts/check-publication.mjs";

const image = "ghcr.io/iangelov/amd64-app-tailscale:2.0.1";
const sha = "a".repeat(40);
const digest = `sha256:${"b".repeat(64)}`;
const inspect = (revision = sha) => JSON.stringify({
  Digest: digest,
  Labels: { "org.opencontainers.image.revision": revision },
});
const failure = (stderr) => () => { throw Object.assign(new Error("command failed"), { stderr }); };

test("a missing architecture can be built on the first run or a partial retry", () => {
  assert.equal(checkImage(image, "amd64", sha, failure("reading manifest 2.0.1: manifest unknown")), null);
});

test("a completed architecture from this commit is reused by digest", () => {
  assert.equal(checkImage(image, "amd64", sha, () => inspect()), digest);
});

test("a version belonging to another commit or lacking provenance is never reused", () => {
  for (const revision of ["c".repeat(40), undefined]) {
    const output = revision ? inspect(revision) : JSON.stringify({ Digest: digest, Labels: {} });
    assert.throws(() => checkImage(image, "amd64", sha, () => output), /Refusing|commit/);
  }
});

test("registry auth, network, and server errors fail closed", () => {
  for (const error of ["unauthorized: authentication required", "503 Service Unavailable", "connection refused", "name unknown"]) {
    assert.throws(() => checkImage(image, "amd64", sha, failure(error)), /command failed/);
  }
});

test("arm images are inspected using the registry's arm64 platform", () => {
  assert.equal(checkImage(image, "aarch64", sha, (command, args) => {
    assert.equal(command, "skopeo");
    if (!args.includes("--raw")) assert.deepEqual(args.slice(0, 4), ["--override-os", "linux", "--override-arch", "arm64"]);
    return inspect();
  }), digest);
});

const sources = ["ghcr.io/iangelov/aarch64-app-tailscale:2.0.1", image];
const manifest = { schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: [
  { digest: `sha256:${"d".repeat(64)}`, platform: { os: "linux", architecture: "arm64" } },
  { digest, platform: { os: "linux", architecture: "amd64" } },
] };
const registry = (existing) => (command, args) => {
  if (command === "docker") {
    assert.deepEqual(args, ["buildx", "imagetools", "create", "--dry-run", ...sources]);
    return JSON.stringify(manifest);
  }
  if (args.includes("--raw")) return JSON.stringify(existing);
  return inspect();
};

test("a missing combined manifest can be published after both architectures", () => {
  assert.equal(checkManifest(image, sources, failure("manifest unknown")), null);
});

test("a completed combined manifest is reused only when its contents match", () => {
  assert.equal(checkManifest(image, sources, registry(manifest)), digest);
  assert.throws(() => checkManifest(image, sources, registry({ ...manifest, manifests: manifest.manifests.slice(1) })), /Refusing|manifest/);
});

test("an existing index with a missing child manifest must not be overwritten", () => {
  assert.throws(() => checkImage(image, "amd64", sha, (_command, args) => {
    if (args.includes("--raw")) return JSON.stringify(manifest);
    return failure("manifest unknown")();
  }), /command failed/);
});
