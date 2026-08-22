const title = process.env.PR_TITLE ?? process.argv[2] ?? "";
const conventionalTitle =
  /^(build|chore|ci|docs|feat|fix|perf|refactor|test)\([a-z0-9][a-z0-9-]*\)(!)?: .+/;

if (!conventionalTitle.test(title)) {
  console.error(
    "PR title must be a scoped Conventional Commit, for example: fix(tailscale): repair startup",
  );
  process.exitCode = 1;
}
