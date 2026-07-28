# Releasing

## Branch model

- `main` — default branch, the pre-release line. All PRs merge here. The
  stamped version stays `0.0.0-dev` on main, so promotion merges never
  conflict on it.
- `release` — the only branch releases are cut from. Promote by merging
  `main` into `release`, never the reverse.

## Cutting a release

1. Promote:

   ```bash
   git fetch origin
   git checkout release
   git merge --no-ff origin/main
   git push origin release
   ```

2. Actions → `release` → Run workflow. Pick branch **`release`**, the channel,
   and the full version: `v1.4.0` (stable), `v1.4.0-beta.2`, `v1.4.0-alpha.7`.

3. The workflow validates every module, runs core's script↔module parity test
   (checkout of `xfabric-sec/core` via the `CORE_READ_TOKEN` secret), stamps
   the semver into `cielara-prepare/*/release.tf` + `VERSION`, commits, tags,
   and publishes the GitHub release (`--prerelease` for alpha/beta).

## Notes

- Tags are created only by the workflow; the `v*` tag ruleset blocks manual
  tags. Dispatching from any branch other than `release` fails immediately.
- The release commit is pushed with `GITHUB_TOKEN`, which does not retrigger
  workflows — release.yml runs its own gates, so that commit shows no
  separate tf-check run. Expected.
- Alpha and beta are GitHub prereleases, so `releases/latest` (and anything
  built on it) only ever resolves stable.
- Parity failure means this repo and core drifted: land/promote the paired
  change first, or point the `core_ref` input at the matching core ref.
- Partial failure after the tag was pushed (release step died): delete the
  tag (`git push origin :refs/tags/vX.Y.Z`) and re-dispatch.

## One-time repo setup

- `CORE_READ_TOKEN` actions secret: fine-grained PAT, contents:read on
  `xfabric-sec/core`. Referenced only by release.yml (workflow_dispatch), so
  fork PRs can never see it.
- Rulesets: `main` requires PRs + green tf-check; `release` restricts
  updates/deletions and blocks force pushes; tag pattern `v*` restricts
  creation/update/deletion. The GitHub Actions app is a bypass actor on the
  latter two so release.yml can push the stamp commit and the tag.
