import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const releaseLevels = {
  build: 1,
  fix: 1,
  perf: 1,
  refactor: 1,
  feat: 2,
};

export function nextVersion(currentVersion, messages) {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(
    currentVersion,
  );
  if (!match) {
    throw new Error(`Expected canonical SemVer, received: ${currentVersion}`);
  }

  let level = 0;
  for (const message of messages) {
    const header = /^(\w+)\(([^)]+)\)(!)?:/.exec(message);
    if (!header || header[2] !== "tailscale") continue;

    const breaking =
      Boolean(header[3]) || /^BREAKING(?: CHANGE|-CHANGE):/m.test(message);
    level = Math.max(level, breaking ? 3 : (releaseLevels[header[1]] ?? 0));
  }
  if (level === 0) return null;

  const [major, minor, patch] = match.slice(1).map(Number);
  if (level === 3) return `${major + 1}.0.0`;
  if (level === 2) return `${major}.${minor + 1}.0`;
  return `${major}.${minor}.${patch + 1}`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const currentVersion = process.argv[2];
  const previousTag = process.argv[3];
  const log = execFileSync(
    "git",
    ["log", "-z", "--format=%B", `${previousTag}..HEAD`],
    { encoding: "utf8" },
  );
  const version = nextVersion(currentVersion, log.split("\0").filter(Boolean));
  if (version) process.stdout.write(`${version}\n`);
}
