# home-assistant-addons

## Tailscale releases

Tailscale uses an independent add-on version. Pull request titles determine the
next release after a squash merge to `main`:

- `fix(tailscale): ...`, `perf(tailscale): ...`, `refactor(tailscale): ...`, or
  `build(tailscale): ...` releases a patch.
- `feat(tailscale): ...` releases a minor version.
- A scoped title with `!`, such as `feat(tailscale)!: ...`, releases a major
  version.
- `chore`, `ci`, `docs`, and `test` titles do not release the add-on.

The release workflow calculates the version, refuses to reuse existing image
tags, updates `tailscale/config.yaml`, creates the `tailscale-vX.Y.Z` tag and
GitHub release, and publishes the multi-architecture images. The first release
bootstraps the legacy `v1.102.3` version and therefore releases `2.0.0` from a
breaking-change PR.

The repository ruleset must list the GitHub Actions app as a bypass actor. This
allows the workflow's short-lived `GITHUB_TOKEN` to push only the generated
version commit and tags; no long-lived release token is required.
