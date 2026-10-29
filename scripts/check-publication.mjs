import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { pathToFileURL } from "node:url";

function inspect(image, flags, run, allowMissing = false) {
  try {
    return JSON.parse(run("skopeo", [...flags, `docker://${image}`], { encoding: "utf8" }));
  } catch (error) {
    // Only an explicitly missing manifest permits a push. Auth/network errors do not.
    if (allowMissing && /manifest unknown/i.test(String(error.stderr))) return null;
    throw error;
  }
}

export function checkImage(image, arch, revision, run = execFileSync) {
  if (inspect(image, ["inspect", "--raw"], run, true) === null) return null;
  const result = inspect(image, ["--override-os", "linux", "--override-arch",
    arch === "aarch64" ? "arm64" : arch, "inspect", "--no-tags"], run);
  if (result.Labels?.["org.opencontainers.image.revision"] !== revision) {
    throw new Error(`Refusing to overwrite ${image}: it belongs to another or unknown commit. Bump the version.`);
  }
  return result.Digest;
}

export function checkManifest(image, sources, run = execFileSync) {
  const existing = inspect(image, ["inspect", "--raw"], run, true);
  if (existing === null) return null;
  const expected = JSON.parse(run("docker", ["buildx", "imagetools", "create", "--dry-run", ...sources], { encoding: "utf8" }));
  if (!isDeepStrictEqual(existing, expected)) {
    throw new Error(`Refusing to overwrite ${image}: its manifest differs from the published architecture images.`);
  }
  return inspect(image, ["--override-os", "linux", "--override-arch", "amd64", "inspect", "--no-tags"], run).Digest;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [mode, image, ...args] = process.argv.slice(2).filter((arg) => arg !== "--required");
  const digest = mode === "image" ? checkImage(image, ...args) : checkManifest(image, args);
  if (process.argv.includes("--required") && !digest) throw new Error(`Publication incomplete: ${image} is missing`);
  const output = `exists=${Boolean(digest)}\ndigest=${digest ?? ""}\n`;
  process.stdout.write(output);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, output);
}
