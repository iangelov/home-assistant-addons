# home-assistant-addons

## Tailscale releases

The add-on has its own SemVer version in `tailscale/config.yaml`, starting at
`2.0.0`. The upstream Tailscale version stays in `tailscale/Dockerfile`.

Renovate updates the Dockerfile and patch-bumps the add-on version in the same
PR, for both Tailscale and base-image updates. This uses Renovate's experimental
[`bumpVersions`](https://docs.renovatebot.com/configuration-options/#bumpversions)
option. Our own runtime changes must include an explicit patch, minor, or major
version bump in the same PR. Documentation and icon changes do not need a bump.
PR titles do not control releases; there are no additional release PRs or
bot-generated version commits.

The Builder workflow checks the version and builds both architectures on PRs.
Require **Check version and tests** and both **Build** jobs, with branches up to
date before merging, to prevent concurrent PRs from reusing a version. Renovate
keeps its dependency branches updated against `main`. These checks must be
configured in the repository rules; adding a workflow alone does not enforce them.
No release bot needs permission to bypass branch protection or push to `main`.

After a merge that increases the version, Builder publishes and signs the
architecture images and combined manifest, then creates `tailscale-vX.Y.Z` and
the GitHub release at that exact commit. Other merges do not publish images.
The workflow never calculates or commits a new version during publication.

## Publication failures and retries

Home Assistant reads `main` immediately, so it can offer an update before its
images are ready (historically about two minutes). A failed publication extends
that window. GitHub Actions marks the run failed and provides a recovery summary;
a GitHub release is created only after all images are published and signed.

Re-run **failed jobs** on the original run after resolving a transient failure.
A full rerun is also safe: each existing architecture image is reused only if its
source-revision label matches the run's commit. Missing architectures are built,
and signing is retried even for reused images. The combined manifest is reused
only if it matches the architecture images. Registry errors fail closed; they
are never treated as evidence that a tag is free. A GitHub release or tag from
another commit is not reused.

If source changes are needed, make a new PR with a higher add-on version. Never
delete or overwrite a release image to recover. Publication runs are serialized,
and this workflow must remain the only writer of these version tags. Published
images are retained so reruns and older installations do not lose their tags.
This guards against accidental overwrites by this workflow; GHCR tags themselves
are mutable, so other writers must follow the same policy.
