# Releasing

## Branch model

- `main` — default branch, the pre-release line. All PRs merge here.
- `release` — the line releases are cut from. Promote by opening a PR into
  `release` that cherry-picks the `main` commits you want to ship (squash
  merge is fine — release history never needs to share commits with main):

  ```bash
  git fetch origin
  git checkout -b promote-x origin/release
  git cherry-pick <main-commit> [<main-commit>...]
  git push origin promote-x   # then open a PR into release
  ```

No branch ever carries a version: `prepare_version` stays `0.0.0-dev` on
`main` and `release` alike. The release workflow stamps the version on a
detached commit that only the release tag points to, so cloning a tag gets a
stamped tree while the branches stay untouched.

## Cutting a release

Actions → `release` → Run workflow. Pick branch **`release`**, a channel, and
the base version (`0.4.0` — plain `X.Y.Z`, no channel suffix). The workflow
picks the prerelease counter itself: if `v0.4.0-alpha.11` is the highest
existing alpha for that base, the new alpha is `v0.4.0-alpha.12` (mirroring
core's `get-next-alpha-version.sh`). Stable tags are just `vX.Y.Z`.

- **alpha** — a new cut from the release branch. `source` is any commit on
  `release` (leave empty for the head).
- **beta** — a promotion of an existing alpha (or an earlier beta). `source`
  is that tag, e.g. `v0.4.0-alpha.2`, and its `X.Y.Z` must match the base.
- **stable** — a promotion of an existing alpha or beta tag, same rules.

The workflow checks out the source, stamps the semver into
`cielara-prepare/*/release.tf` + `VERSION`, runs fmt/validate on every module
and core's script↔module parity test, commits on a detached HEAD, pushes only
the tag, and publishes the GitHub release (`--prerelease` for alpha/beta).

Because beta/stable re-stamp the source tag's tree, promoting never re-ships
different code: `v1.4.0` is byte-identical to the alpha/beta it was promoted
from except for the version value.

## Notes

- Tag commits live on no branch — that is by design. `git log release` never
  shows release commits; `git tag` and the GitHub releases page are the
  release history.
- Alpha and beta are GitHub prereleases, so `releases/latest` (and anything
  built on it) only ever resolves stable.
- Parity failure means this repo and core drifted: land/promote the paired
  change first, or point the `core_ref` input at the matching core ref.
- Partial failure after the tag was pushed (release step died): delete the
  tag (`git push origin :refs/tags/vX.Y.Z`) and re-dispatch.
- Dispatching from any branch other than `release` fails immediately.

## One-time repo setup

- `TERRAFORM_RELEASE_CORE_READ_TOKEN` actions secret: fine-grained PAT,
  contents:read on `xfabric-sec/core`. Referenced only by release.yml
  (workflow_dispatch), so fork PRs can never see it.
- The repo ruleset requires PRs into `main` and `release`; the workflow never
  pushes to a branch, so it needs no bypass. Manual `v*` tags are blocked
  only by convention (the workflow refuses to reuse an existing tag) — a tag
  ruleset with a GitHub Actions bypass actor would harden this if wanted.
