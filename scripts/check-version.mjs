import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function versionOf(config) {
  const versions = [...config.matchAll(/^version: "([^"]+)"\s*$/gm)];
  if (versions.length !== 1) throw new Error('Expected one quoted version in tailscale/config.yaml');
  return versions[0][1];
}

export function checkVersion(before, after, files) {
  const previous = versionOf(before).replace(/^v/, ""); // Legacy upstream versions.
  const version = versionOf(after);
  const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
  if (!semver.test(previous) || !semver.test(version)) {
    throw new Error("Add-on version must be canonical SemVer, e.g. 2.0.1");
  }
  const oldParts = previous.split(".").map(BigInt);
  const parts = version.split(".").map(BigInt);
  const difference = parts.findIndex((part, i) => part !== oldParts[i]);
  if (difference !== -1 && parts[difference] < oldParts[difference]) {
    throw new Error(`Add-on version ${version} must be newer than ${previous}`);
  }
  const runtimeChanged = files.some((file) => file.startsWith("tailscale/") &&
    !file.endsWith(".md") && !["tailscale/icon.png", "tailscale/logo.png"].includes(file));
  const publish = difference !== -1;
  if (runtimeChanged && !publish) {
    throw new Error("Runtime files changed: bump tailscale/config.yaml in this PR");
  }
  return { version, publish };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [before, after = "HEAD"] = process.argv.slice(2);
  const git = (...args) => execFileSync("git", args, { encoding: "utf8" });
  const result = checkVersion(
    git("show", `${before}:tailscale/config.yaml`),
    git("show", `${after}:tailscale/config.yaml`),
    git("diff", "--name-only", "--no-renames", "-z", before, after).split("\0"),
  );
  const output = `version=${result.version}\npublish=${result.publish}\n`;
  process.stdout.write(output);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, output);
}
