import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

export function createRelease(version, sha, repo, run = execFileSync) {
  const tag = `tailscale-v${version}`;
  function get(path) {
    try {
      return JSON.parse(run("gh", ["api", `repos/${repo}/${path}`], { encoding: "utf8" }));
    } catch (error) {
      if (String(error.stderr).includes("(HTTP 404)")) return null;
      throw error;
    }
  }
  const ref = get(`git/ref/tags/${tag}`);
  const commit = ref && get(`commits/${tag}`);
  if (commit && commit.sha !== sha) throw new Error(`${tag} already points to another commit`);
  if (!get(`releases/tags/${tag}`)) {
    run("gh", ["release", "create", tag, "--repo", repo, "--target", sha,
      "--generate-notes", "--title", tag], { stdio: "inherit" });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  createRelease(process.argv[2], process.env.GITHUB_SHA, process.env.GITHUB_REPOSITORY);
}
