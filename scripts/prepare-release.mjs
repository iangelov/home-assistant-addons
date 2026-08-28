import { readFile, writeFile } from "node:fs/promises";

const version = process.argv[2] ?? "";
const configPath = process.argv[3] ?? "tailscale/config.yaml";
const canonicalSemVer = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

if (!canonicalSemVer.test(version)) {
  throw new Error(`Expected canonical SemVer, received: ${version}`);
}

const source = await readFile(configPath, "utf8");
const versionLines = source.match(/^version:.*$/gm) ?? [];
if (versionLines.length !== 1) {
  throw new Error(`Expected exactly one version field in ${configPath}`);
}

const updated = source.replace(/^version:.*$/m, `version: "${version}"`);
await writeFile(configPath, updated);
