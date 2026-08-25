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
`cielara-prepare/*/release.tf` + `cdl-registry-prepare/*/release.tf` +
`VERSION`, runs fmt/validate on every module and core's script↔module parity
test, commits on a detached HEAD, pushes only the tag, publishes the GitHub
release (`--prerelease` for alpha/beta), and fans the `cdl-registry-*`
directories out to the mirror repos.

The job runs in a channel-picked GitHub environment — `release` for
alpha/beta, `release-stable` for stable — so required reviewers on those
environments gate who can approve each channel.

Because beta/stable re-stamp the source tag's tree, promoting never re-ships
different code: `v1.4.0` is byte-identical to the alpha/beta it was promoted
from except for the version value.

## Mirror fan-out

The last workflow step publishes each `cdl-registry-*` directory to its
read-only mirror repo; the HashiCorp registry watches the mirrors and
publishes every semver tag:

| Source directory | Mirror repo | Registry address |
|---|---|---|
| `cdl-registry-prepare/gke` | `terraform-google-cielara-prepare-gke` | `causal-dynamics-lab/cielara-prepare-gke/google` |
| `cdl-registry-prepare/gcp` | `terraform-google-cielara-prepare-vm` | `causal-dynamics-lab/cielara-prepare-vm/google` |
| `cdl-registry-prepare/eks` | `terraform-aws-cielara-prepare-eks` | `causal-dynamics-lab/cielara-prepare-eks/aws` |
| `cdl-registry-prepare/aks` | `terraform-azurerm-cielara-prepare-aks` | `causal-dynamics-lab/cielara-prepare-aks/azurerm` |
| `cdl-registry-networking/aws` | `terraform-aws-cielara-network` | `causal-dynamics-lab/cielara-network/aws` |
| `cdl-registry-networking/azure` | `terraform-azurerm-cielara-network` | `causal-dynamics-lab/cielara-network/azurerm` |
| `cdl-registry-networking/gcp` | `terraform-google-cielara-network` | `causal-dynamics-lab/cielara-network/google` |

Mechanics:

- Each mirror's default branch is replaced with a verbatim copy of the
  stamped directory plus the repo root `LICENSE`, then the same version tag
  is pushed. Every channel fans out — staging exercises the identical
  download path customers use.
- Mirrors are workflow-authored artifacts. Never commit, push, or tag one by
  hand; never point the parity test at one.
- A mirror that already carries the tag is skipped, so re-running a
  fan-out that died halfway completes the remainder.
- Promotions can be byte-identical on the networking mirrors (they carry no
  `release.tf`) — the tag then lands on the existing head commit.
- If the fan-out fails partway, mirrors are only consistent at tags that
  exist on all seven. Before the registry webhook is installed, a partial
  version may be cleaned by deleting its tag from the affected mirrors;
  after, it is fix-forward only — supersede with the next version.

## First registry publish (runbook)

Publishing goes through HCP Terraform (registry.terraform.io's own publish
flow is legacy, policy libraries only — verified live 2026-08-26). In order —
the publish is the point of no return (it installs the webhook; from then on
any semver tag on a mirror becomes a permanent public module version):

1. Mirror hygiene: rulesets blocking pushes/PRs/tags for everyone but the
   bot; issues/wikis off.
2. Secrets + environments on this repo:
   `TERRAFORM_RELEASE_MIRRORS_WRITE_TOKEN`, `release` / `release-stable`
   required reviewers.
3. Cut a release so every mirror carries at least one semver tag.
4. HCP account (GitHub sign-in) -> HCP Terraform organization -> install the
   `terraform-cloud` GitHub App on the mirror org scoped to ONLY the seven
   mirrors (a non-owner's install lands as a request an org owner approves)
   -> Registry -> Public namespaces -> New Namespace -> Continue with Github
   (needs popups allowed) -> claim the org namespace.
5. Publish each mirror once: Publish -> Module -> select repo -> accept the
   Terms of Use -> Publish module. Existing semver tags ingest immediately;
   future tags auto-publish.
6. Verify: each docs page renders; `terraform init` resolves every published
   address with an exact version pin; a prerelease does NOT resolve from a
   version range or `latest`.

## Lineage (revision)

Alphas additionally stamp `prepare_revision` — the release-branch commit the
tag was cut from — into every module's `release.tf`; promotions inherit it
unchanged. The value flows into the `version.json` marker each prepare run
writes to the customer's cloud, and into a `release.json` asset
(`version`, `channel`, `revision`, `source_tag`) on every GitHub release.

Equal revisions mean identical module trees: a customer who prepared at
`v0.4.0-alpha.13` is already on `v0.4.0` if the stable was promoted from that
alpha. Consumers (the Cielara control plane) compare revisions, not version
strings. Promoting a tag that predates revision stamping fails the workflow —
cut a fresh alpha instead.

## Notes

- Tag commits live on no branch — that is by design. `git log release` never
  shows release commits; `git tag` and the GitHub releases page are the
  release history.
- Alpha and beta are GitHub prereleases, so `releases/latest` (and anything
  built on it) only ever resolves stable.
- Parity failure means this repo and core drifted: land/promote the paired
  change first, or point the `core_ref` input at the matching core ref.
- Partial failure after the tag was pushed (release step died): delete the
  tag (`git push origin :refs/tags/vX.Y.Z`) and re-dispatch. Once the
  registry watches the mirrors this only applies while no mirror got the
  tag — otherwise supersede with the next version.
- Dispatching from any branch other than `release` fails immediately.

## One-time repo setup

- `TERRAFORM_RELEASE_CORE_READ_TOKEN` actions secret: fine-grained PAT,
  contents:read on `xfabric-sec/core`. Referenced only by release.yml
  (workflow_dispatch), so fork PRs can never see it.
- `TERRAFORM_RELEASE_MIRRORS_WRITE_TOKEN` actions secret: machine-account
  fine-grained PAT, contents:read/write on exactly the seven mirror repos.
  The workflow refuses to start without it.
- GitHub environments `release` (reviewers: Ryan/Atiqur/Mehran) and
  `release-stable` (Ryan) — created implicitly on first dispatch; add the
  required reviewers in repo settings to arm the approval gates.
- The repo ruleset requires PRs into `main` and `release`; the workflow never
  pushes to a branch, so it needs no bypass. Manual `v*` tags are blocked
  only by convention (the workflow refuses to reuse an existing tag) — a tag
  ruleset with a GitHub Actions bypass actor would harden this if wanted.
