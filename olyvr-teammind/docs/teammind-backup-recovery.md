# Plan: backup and recovery for a TeamMind server

> Written while this lived in the Olyvr repository as `infra/teammind/`; it is now `olyvr-teammind/` in this one.
> Source mode (the VM fetching commits with a GitHub token) has since been removed: a server installs only from a
> staged bundle. Paths and details below are as they were.

**Status:** Approved 2026-10-30; Phases 1 and 2 implemented in `infra/teammind/` (see "Changes during implementation" at the end)
**Related:** `teammind-terraform-setup.md` (the server and today's nightly dump),
`infra/teammind/README.md` ("Backups", "Restore"), `rebuild/docs/server-mode.md` (what the host keeps).

A TeamMind server runs on one VM: PostgreSQL with the team's memory, and Olyvr headless with the memory
server and its gate. This plan makes its backups complete, encrypted, signed, and sent wherever the operator
chooses (a GCS bucket, an S3 bucket, Azure Blob, an SFTP host, a person's PC, or several at once), and makes
every way of losing the server a tested procedure with a known recovery time.

## What exists today

- `/etc/cron.d/teammind-backup`, 03:15 nightly: `pg_dump -Fc teammind` to `/var/backups/teammind` (a week,
  by weekday name) and a copy to the bucket of the cloud the VM runs in, through the VM's identity, which
  may create objects but not read or delete them.
- `<cloud>/backups/`: that bucket, with versioning, 90-day retention and `prevent_destroy`.
- `teammind-restore <dump>`: restores into a scratch database, swaps it in, rebuilds the lexical index.

## Gaps

| Gap | Consequence |
| --- | --- |
| Only the database is backed up | A rebuilt server has new reader tokens (their hashes live in Olyvr's store, not PostgreSQL), a new self-signed certificate, default gate settings. Every reader must reconnect and re-pin |
| The destination is the VM's own cloud only | No copy outside that cloud account; no copy on a PC; a lost account or region loses everything |
| Dumps leave the VM unencrypted and unsigned | Anyone who can read the bucket reads the team's memory; anyone who can write it can plant a dump |
| Nobody notices a failed backup | cron's failure goes to a log file no one reads; the first sign is a restore that has nothing to restore |
| No check that a dump restores | A truncated or broken dump is discovered during the outage |
| A failed restore leaves the server down | `teammind-restore` keeps the old database but never swaps it back when the memory server doesn't come up |
| RPO is 24 hours, fixed | A day of ingests lost, whatever the team's write rate |
| The hand-built dogfood VM (`olyvr-memory`) is outside `infra/teammind/` | It gets none of this unless installed by hand |

## What one backup holds

A backup carries the server's **data and identity as readers see it**, and none of the **host's
configuration**. The replacement VM's own Terraform-made configuration (cloud, address, secret names, backup
targets, PostgreSQL password) is what it must keep: restoring the lost VM's `bootstrap.env` onto a VM in
another cloud would point later bootstrap and backup runs at the old account, and restoring its `pg.env` would
not match the role the new VM created (`pg_dump` doesn't carry roles or passwords; `bootstrap.sh` writes
`server.env` from the new VM's password).

| Kind | What | On restore |
| --- | --- | --- |
| **Data** | the `teammind` database | restored (`--no-owner --role=teammind`, as today) |
| **Portable state** | Olyvr's SQLite store (token hashes, vault rows), the vault key `credential.key` (the two only work together), `/etc/olyvr/teammind-token`; from `memory/config.json` the settings (`shared`, `limits`, `log_searches`, shares) | installed |
| **Conditionally portable** | the gate's self-signed pair `memory/tls/gate.{key,crt}` | installed only when the target uses `self_signed` and the certificate's SANs cover the target's domain or address; otherwise the target's own. This is what spares readers a re-pin |
| **Host configuration** | `bootstrap.env`, `pg.env`, `session-token`, `memory/server.env`, `/etc/olyvr/tls/`, and from `config.json` the `port`, `domain`, `cert_file`, `key_file` fields | **never installed**: the target keeps its own. Recorded in the manifest (non-secret values only: names, commits, domain, cloud) for reference |

Left out entirely, because they are rebuilt from the source: `state/memory/venv`, `state/memory/app`, caches,
the lexical index (`data/tantivy-postgres`), the checkout.

Each run produces one **backup set**, `teammind-<host>-<UTC time>`:

| File | Contents |
| --- | --- |
| `db.dump.age` | `pg_dump -Fc teammind`, encrypted |
| `state.tar.zst.age` | the portable and conditionally portable state above, encrypted |
| `manifest.json.age` | encrypted: set name, creation time, host name and instance id, SHA-256 of both plaintexts and both ciphertexts, the Olyvr and memory commits, `MEMORY_RELEASE`, PostgreSQL and pgvector versions, row counts (below), the source host's configuration for reference |
| `manifest.json.age.sig` | the host's signature over `manifest.json.age` (below) |
| `SHA256SUMS` | plain digests of the four files above: transfer completeness only, for a holder without the age key (a PC). It authenticates nothing |

The state archive holds the vault key and the reader token, so it is as sensitive as the server itself.

**Row counts that match the dump.** Counts queried beside `pg_dump` would see ingests that land after its
snapshot, and a valid dump would then fail its own check. Phase 1 uses one exported snapshot: a `psql`
coprocess opens `BEGIN ISOLATION LEVEL REPEATABLE READ`, runs `SELECT pg_export_snapshot()`, takes the
counts, and stays open while `pg_dump --snapshot=<id>` runs; then it commits. Dump and counts see exactly
the same rows, and nothing stops writing. The SQLite copy (`sqlite3 .backup`) is consistent on its own but
not with that snapshot; the two hold independent things (tokens and settings; the memory), so a few
seconds apart is harmless, and the restore checks no count across them.

## Encryption and signing

**Encryption: age, with the private keys off the VM.** Every file is encrypted with
[age](https://age-encryption.org) to one or more public recipient keys (`BACKUP_AGE_RECIPIENTS` in
`bootstrap.env`). The private keys never touch the VM: one held by the operator in the password manager,
one break-glass copy kept offline.

- Any destination may be untrusted storage (a PC, a third-party bucket). It holds ciphertext only.
- A compromised VM can make new backups but cannot read old ones, here or anywhere.
- Restore decrypts on the operator's machine and streams to the VM (`teammind-unpack … | ssh … sudo
  teammind-restore -`), so the plain dump never lands on a laptop disk.
- Losing every private key loses every backup. Phase 0 names the two holders; the drill uses the key from
  where it is really kept.

**Signing: an ssh key that only the VM has.** age authenticates a ciphertext against tampering, not who
made it: the recipients are public keys, sitting in user data, so anyone who has them can encrypt a set
that decrypts cleanly. So the bootstrap makes a host **backup signing key** (`ssh-keygen -t ed25519`,
`/etc/olyvr/backup-sign`, mode 600; signs with `ssh-keygen -Y sign -n teammind-backup`, nothing to install),
and Terraform outputs its public half as `backup_signing_key`, which the operator records with the server.
`teammind-unpack` refuses a set unless:

1. `manifest.json.age.sig` verifies against a signing key from the operator's own `allowed_signers` list
   (not one fetched from the destination);
2. the decrypted manifest's set name is the one asked for, and its time and host are printed for the
   operator to confirm (a destination that hands back an older valid set is seen, not trusted);
3. both payloads' ciphertext and plaintext digests match the manifest.

The signing key is host configuration, not backed up: a replacement VM makes a new one and the operator adds
it to `allowed_signers`. Old sets keep verifying with the old key, which stays in the list until they expire.
A compromised host can sign anything it likes after the compromise, which is why that recovery uses a set
made before it.

## Destinations: rclone named remotes, a PC pulls

`teammind-backup` writes the set to `/var/backups/teammind/<set>/` (kept 7 days), then pushes it with
[rclone](https://rclone.org) (pinned version, SHA-256 checked by the bootstrap like every other download) to
each target in `BACKUP_TARGETS`. A target that fails doesn't stop the others; the run fails if any did.

**Format.** A target is always `<remote>:<path>`, where `<remote>` is a section of
`/etc/olyvr/rclone.conf` (mode 600, root only) and `<path>` is passed to rclone unchanged. The bootstrap
writes that file from two parts:

- **`cloud`, reserved**: generated by the bootstrap for the VM's own cloud with `env_auth` (the VM's identity,
  no key): `type = google cloud storage`, `s3` with `provider = AWS`, or `azureblob` with
  `env_auth = true`. Target: `cloud:<bucket>/<host>` (Azure: `cloud:<container>/<host>`).
- **Operator remotes**: the content of the secret `backup_remote_secret` names, plain rclone config sections
  under names the operator chooses: `[aws_backup] type = s3 …`, `[nas_backup] type = sftp …`. Targets:
  `aws_backup:teammind-backups/<host>`, `nas_backup:/incoming` (an SFTP target is a flat folder, below).

The bootstrap refuses a secret that defines a section named `cloud`, and a target whose remote is not in the
file, so a typo fails the apply's readiness, not the first night.

| Target | Credential | Write-only by |
| --- | --- | --- |
| `cloud:` (own cloud's bucket) | the VM's identity | GCS `objectCreator`; S3 `PutObject` only; Azure the existing custom blob-write role |
| another cloud's bucket | access key in the remote section | a key policy with `PutObject` only (S3), `objectCreator` (GCS HMAC or service-account key), blob-write role (Azure SAS with `cw` only) |
| SFTP / a NAS | ssh key in the remote section | OpenSSH's own SFTP server, restricted on the far side (below) |
| a PC | none: **pulled**, below | |

Every push runs with the flags write-only credentials need (`--no-check-dest`, `--s3-no-check-bucket`,
`--s3-no-head`, `--gcs-bucket-policy-only`). Phase 1 tests each backend with a credential that really is
write-only and checks it is refused a read, a delete and an overwrite: a test with an admin key passes by
accident.

**An SFTP destination is an SFTP server, not rsync.** rclone's `sftp` backend speaks SFTP, so the far side
must too (`rrsync` only takes rsync transfers, and its `-wo` alone would not stop a delete or an overwrite
anyway). Only upstream `sftp-server` options are used (`-d`, `-p`, `-u`; see `sftp-server(8)`), so the same
block works on any distribution's OpenSSH. The destination host gives the backup user (a normal, non-root
account) this:

```
# /srv/teammind-backups            root:root 755  (ChrootDirectory must be root-owned, not writable by others)
# /srv/teammind-backups/incoming   teammind-backup:teammind-backup 700
Match User teammind-backup
    ChrootDirectory /srv/teammind-backups
    ForceCommand internal-sftp -d /incoming -u 0777 -p open,close,write,fsync,realpath,stat,lstat,fstat,limits
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
```

How each of the four operations is decided:

| Operation | Result | Enforced by |
| --- | --- | --- |
| create a file | allowed | `open` is in the allowlist and `incoming/` is the user's own, writable folder |
| write it | allowed | through the handle `open` returned: on a file the call itself creates, the kernel checks no permission bits, so a mode `0000` file is still written |
| read a file | refused | `read` and `readdir` are not in the allowlist (the server answers "permission denied" to any request it doesn't list); and at the file system, `-u 0777` makes every new file mode `0000`, which its non-root owner can't open for reading |
| delete, rename, overwrite | refused | `remove`, `rename`, `posix-rename`, `hardlink`, `symlink`, `setstat`, `fsetstat`, `mkdir`, `copy-data` are not in the allowlist; reopening an existing file for writing (the overwrite path, with `O_TRUNC`) fails because it is mode `0000`, and `setstat` (chmod) to undo that is refused |

`-p` is an allowlist, so request types added by a later OpenSSH are refused until added here. `stat`, `lstat`
and `fstat` stay because rclone checks a file's size after the upload; they reveal names and sizes, not
contents (the contents are age ciphertext in any case). The destination's own jobs (pickup, retention,
clearing partial files) run as root or another user, unaffected by these modes.

What this asks of rclone, in the remote section and the push:

- **Flat names, no folders.** With `mkdir` refused, an SFTP target's path is the existing folder
  (`nas_backup:/incoming`), and the set's files are pushed as `<set>.<file>` (`teammind-…Z.db.dump.age`)
  instead of `<set>/<file>`.
- **In place**, with `--inplace`: no temporary name to rename.
- **No listing, hashing, shell or times**: `--no-check-dest --no-traverse`, and in the section
  `shell_type = none`, `disable_hashcheck = true`, `set_modtime = false` (`ForceCommand` gives rclone no shell
  for `md5sum`, and setting a time is `setstat`). Integrity is the set's own digests.
- **An interrupted upload** leaves a mode-`0000` partial file the backup user can't remove, finish or
  overwrite. Each set has a fresh name, so the next run is unaffected; the destination's retention job clears it.

**Verified on the destination's version, not assumed.** Before a destination is used, and again after an
OpenSSH upgrade there, `infra/teammind/pull/check-sftp-target.sh <remote>` runs from the VM against it and
records `ssh -V` of the far side (from its operator) with the result. It must show: a new file created and
written (size matches), and a read, a listing, a delete, a rename, a mkdir and an overwrite of that file each
refused. A destination that allows any of the last six is not used.

rsync to `rrsync` was the alternative; it would need a second transfer tool beside rclone and still needs
separate measures against delete and overwrite, so SFTP it is.

**A PC pulls.** A laptop has no fixed address and isn't reachable from the VM, and the VM should hold no
credential for a person's machine. `infra/teammind/pull/teammind-pull.sh` (PowerShell twin for Windows) runs
on the PC from cron, launchd or Task Scheduler and fetches new sets with `rsync` over ssh. Its key sits in the
VM's `authorized_keys` as `command="rrsync -ro /var/backups/teammind",restrict` (`pull_ssh_public_key`): it can
read the encrypted sets and nothing else, not even a shell. The PC must be in `admin_cidrs` or on the VPN. It
checks `SHA256SUMS` (complete transfer; not authenticity, since a PC normally has no age key), keeps 14 daily
and 8 weekly sets, and records its own last success, which the operator watches on that side.

## Retention

The VM deletes nothing remote; the local copy is its only pruning. Destinations keep the existing 90-day
lifecycle, and gain a 14-day retention rule in one of two modes, `backup_retention_mode`:

| Mode | GCS | S3 | Azure Blob | Who can delete inside 14 days |
| --- | --- | --- | --- | --- |
| `guarded` (default) | bucket retention policy, **unlocked** | Object Lock **governance** | time-based immutability policy, **unlocked** | not the VM, not an operator with the ordinary role; still a principal with `storage.buckets.update` (GCS), `s3:BypassGovernanceRetention` (S3), or rights to remove the policy (Azure) |
| `locked` | retention policy **locked** | Object Lock **compliance** | immutability policy **locked** | nobody, including the account's owner, until each object is 14 days old |

`guarded` protects against the VM and against a mistake by an ordinary operator; it is not proof against an
administrator, and the README says exactly that. `locked` is irreversible: the retention period can't be
shortened or removed, and the bucket can't be deleted while it holds an object younger than the period
(already true in practice, since `prevent_destroy` refuses that root's destroy). Choose it per environment;
the dogfood proposal is `guarded` for its own bucket and `locked` for the off-cloud copy. The roles that hold
the bypass or policy rights are named in the README, and none is granted to the VM or to the operator group.
S3 Object Lock needs versioning, which the bucket already has; enabling it on the existing bucket is a
one-time `PutObjectLockConfiguration`, done by the `aws/backups` root.

## Frequency, RPO and RTO

Default nightly (RPO 24 h). `backup_schedule` can run it every few hours; Phase 0 measures dump size and
duration on dogfood to say how often is cheap. If the team needs minutes, the answer is WAL archiving
(pgBackRest or WAL-G, which also push to S3/GCS/Azure and give point-in-time recovery), as a later phase:
a second backup system to run and test, so only when asked for.

**Disk snapshots, as a second layer.** Optional `snapshot_schedule` attaches the cloud's snapshot schedule to
the VM's disk (GCP resource policy, AWS DLM, Azure Backup), daily, 7 kept. Crash-consistent (PostgreSQL
recovers from its WAL on boot), same cloud and account only, so they complement the sets, never replace them;
their value is the fastest rollback of a whole VM after a bad upgrade.

| Scenario | Recover with | Target time |
| --- | --- | --- |
| Bad ingest, deleted collection, a bad memory release | `teammind-restore --db-only` of the last good set on the same VM | 15 min |
| Bad Olyvr/memory upgrade that broke the VM | disk snapshot, or the bootstrap rerun at the old commits then `--db-only` | 30 min |
| VM or disk lost | `terraform apply` (same address and domain) then `teammind-restore` (full) | 45 min |
| Cloud account or region lost | apply in another cloud or region from a set in an off-cloud bucket or on the PC; DNS moved to the new address | 2 h |
| Host compromised | fresh apply, then `teammind-restore --sanitize` of a set made **before** the compromise, then the rotation checklist | 2 h + rotation |

## Restore

```bash
# on the operator's machine: fetch with your own credentials, verify and decrypt locally, stream to the VM
rclone copy aws_backup:teammind-backups/<host>/<set> ./<set>
teammind-unpack ./<set> | ssh ubuntu@<ip> sudo teammind-restore -
```

`teammind-unpack` does the three checks under "Signing" and streams the database and state as one tar.
`teammind-restore` then works in three stages, and the server stays up until the third:

1. **Stage, with the server running.** Unpack into `/var/lib/olyvr/restore-<time>/`. Restore the database
   into a scratch database, as today. Check the staged state: the SQLite store opens and passes
   `PRAGMA integrity_check`, its schema revision is one this Olyvr can open (or migrate), the vault key opens
   a vault row, the settings merge into the target's `config.json` and pass the same validation as `save`,
   the gate certificate (when it qualifies) matches its key; set owners and modes (`olyvr`, 600) on the staged
   files. Compare the scratch database's counts with the manifest. Any failure: drop the scratch database,
   remove the staging folder, exit; nothing on the server changed.
2. **Swap.** Stop the memory server and Olyvr. Rename `teammind` to `teammind_before_<time>` and the scratch one
   into place; move each current state file aside as `<file>.before_<time>` and the staged one in; remove the
   lexical index.
3. **Start and check health, with automatic rollback.** Start Olyvr, wait for the memory server on PostgreSQL
   with its model attached, run `teammind-check --health` (application health only, see "Health and
   readiness"). If that fails or times out (10 minutes), stop both, put every `*.before_<time>` file back,
   rename the databases back, start again, check health again, and exit non-zero with the failure: the server
   is as it was. On success, run `teammind-backup` once, so the restored server has a fresh set of its own,
   and print what to drop when happy (`teammind_before_<time>`, the `.before_` files). Readiness is not part
   of this decision: a restore never rolls back because a rotation is outstanding or a backup is missing.

Options:

- `--db-only`: the database alone, as today, with the same stage, swap and rollback.
- `--sanitize`, for a host that was compromised. The vault key is kept (replacing it would leave every
  encrypted row unreadable); instead the restore **deletes every vault row** and **revokes every restored
  reader-token row**, then makes new primary and secondary tokens and a new self-signed gate certificate if
  that mode is used. Then it prints, and writes to `/var/lib/olyvr/rotation-required`, the secrets the
  compromised host could read and which must be rotated **before** the server is declared ready:
  `source_token_secret` (the GitHub PAT), `llm_key_secret`, every credential in `backup_remote_secret`, the
  `tls_secret` pair (and a Let's Encrypt certificate is revoked with `certbot revoke`), the old host's backup
  signing key (removed from `allowed_signers`, or kept only for sets made before the compromise), and its
  ssh host key. The server is healthy but **not ready** while that file exists (`teammind-check` exits 2);
  `teammind-restore --rotation-done` removes it after the operator confirms each line, then runs a backup
  with the rotated credentials.
- A set made by a different Olyvr commit is refused with the manifest's commit printed, unless
  `--allow-version-skew`: rerun the bootstrap at that commit first, restore, then upgrade.

`restore_from` in Terraform (Phase 6 of the Terraform plan, landing here): the bootstrap doesn't write the
ready marker until a set has been streamed in and restored, since the VM can't read the bucket.

## Health and readiness

`teammind-check` reports two things, and each caller uses the one it needs:

| | Checks | Used by |
| --- | --- | --- |
| **Health** (`--health`) | the backend answers, the memory server runs on PostgreSQL with its model, the gate serves TLS and refuses a request without a token | the restore's rollback decision; the bootstrap before its first backup |
| **Readiness** (the default) | health, plus: no `/var/lib/olyvr/rotation-required`, and a fully successful backup within 1.1 × the schedule interval (26 h for nightly) | the bootstrap's ready marker (and so Terraform's readiness check); the operator's `status_command`; monitoring |

Exit 0 ready, 2 healthy but not ready (with the reason: "rotation outstanding", "no backup yet", "last backup
31 h ago"), 1 unhealthy. A fresh VM isn't left waiting a night for its first backup: the bootstrap's last step
runs `teammind-backup` once, after health passes and before the ready marker, which also proves every target
and credential at apply time. A bad target therefore fails the apply with the backup log's tail, as a bad
digest does today.

## Knowing it works

- **Status file.** Each run writes `/var/lib/olyvr/backup-status.json`: time, set name, size, per target ok or
  the error. Readiness reads it (above).
- **Dead-man's switch.** `backup_ping_url` (healthchecks.io, Better Stack, Cronitor, or self-hosted): the run
  pings it on success and `/fail` on failure, and that service alerts when a ping is late. The only alert that
  also fires when the VM itself is gone.
- **Every run, before upload:** `pg_restore --file=/dev/null` on the dump. Unlike `--list`, which reads only
  the archive's table of contents and would pass a file damaged in a later data block, this reads and
  decompresses every block to the end, so truncation and most corruption fail the run. It is still a read of
  the archive, not a restore: the custom format has no per-block checksum, and nothing here shows the data
  loads. Digests written.
- **Weekly, on the VM:** the newest local plain dump (made in the same run, before encryption, and deleted
  after) restored into a scratch database, counts compared with the snapshot's counts, scratch dropped. This
  is the real proof that a dump loads; it checks the dump, not the encryption or the signature (the VM has no
  private key). A weekly restore that fails makes the server not ready.
- **Quarterly, by hand, the full drill:** a fresh VM from Terraform in a throwaway project, a set fetched from
  a target other than the VM's own cloud, verified and decrypted with the key from where it is really kept,
  restored in full; a reader connects with its existing token and certificate and gets cited answers. Also,
  once a year, a `--sanitize` restore and the rotation checklist walked through. Timed against the table
  above and noted in the README. A backup nobody has restored is a hope, not a backup.

## The dogfood VM

`olyvr-memory` was built by hand and isn't in Terraform. Phase 2 installs the same scripts there by hand
(`rclone`, `age`, the signing key, `teammind-backup`, the cron line, the pull key) with a `bootstrap.env` and
`rclone.conf` written for it, and runs its first full drill. It holds the team's real memory today, so it goes
first among real servers.

## Variables

New, in all three roots: `backup_targets` (list of `<remote>:<path>`), `backup_remote_secret`,
`backup_age_recipients` (required: no unencrypted backups), `backup_schedule` (cron, default `15 3 * * *`),
`backup_ping_url`, `pull_ssh_public_key`, `snapshot_schedule`. In the `<cloud>/backups/` roots:
`backup_retention_mode` (`guarded` or `locked`). New output: `backup_signing_key`. `backup_bucket` stays, as
the `cloud:` target's bucket.

## Phases

| Phase | Work | Done when |
| --- | --- | --- |
| 0 | Decide: who holds the two age keys; dogfood's targets (proposed: its GCS bucket, an S3 bucket in the AWS account in `locked` mode, one operator PC); dump size and time on dogfood; confirm the state list on a running host (the SQLite store's file name, that headless Linux keeps the vault key in `credential.key`, which `config.json` fields are host configuration) | decisions written at the top of this file |
| 1 | `teammind-backup.sh` rewritten: exported-snapshot dump and counts, the state archive, age, the signed manifest, `rclone.conf` from `cloud` + the secret, push to `BACKUP_TARGETS`, status file, ping, `pg_restore --file=/dev/null`; rclone, age and the signing key in the bootstrap, and its first backup before the ready marker; `teammind-check --health` and readiness; the weekly self-check; the SFTP `Match` block in the README | on a test VM, sets reach `cloud:` (GCS), an S3 remote and an SFTP remote behind the restricted `internal-sftp`; each write-only credential is refused a read, a delete and an overwrite (for SFTP, `check-sftp-target.sh` passes against the destination's own OpenSSH version, which is noted); a failed target fails the run and pings `/fail`; a dump taken during continuous ingests passes its count check; a dump truncated mid-data fails the run; an apply with a bad target fails with the backup log's tail |
| 2 | `teammind-unpack` and `teammind-restore` (stage, swap, rollback; `--db-only`, `--sanitize`), `pull/teammind-pull.sh` (+ `.ps1`); install on dogfood | dogfood backs up to its targets and a PC pulls; a full restore of a dogfood set on a fresh VM in **another cloud** keeps the reader's token and certificate working, with the target's own `bootstrap.env` and PostgreSQL password; a restore with a deliberately broken state file rolls back to a working server; a set with an altered manifest, a swapped payload, or a signature from an unknown key is refused |
| 3 | Terraform: the variables, `backup_retention_mode` in `<cloud>/backups/`, `snapshot_schedule`, `restore_from`, the signing-key output; README "Backups" and "Restore" rewritten; CI shellcheck for the new scripts | apply plus restore with `restore_from` on GCP; one AWS and one Azure apply back up to a GCS remote |
| 4 | First quarterly drill, timed; the recovery table's times replaced by measured ones | drill notes in the README |
| Later | WAL archiving and point-in-time recovery, if Phase 0 or the team asks for an RPO under a few hours; backup status on the Settings → Server pane | separate plans |

## Not in scope

- A managed database or a standby replica (high availability is a different problem from backup).
- Backing up readers' own Olyvr installs: they hold no TeamMind data, only an address, a token and a pin.
- Rotating age recipients beyond "add the new key, keep the old private key until every set made only for the
  old key has expired".

## Changes after review

- **Host configuration is never restored.** The archive splits portable state from host configuration; the
  target keeps its own `bootstrap.env`, `pg.env`, `server.env` and TLS, so a cross-cloud restore keeps the new
  cloud's settings and the new PostgreSQL password.
- **`--new-secrets` is now `--sanitize`.** It keeps the vault key (a new one would orphan every encrypted row),
  deletes the vault rows, revokes the restored tokens, and blocks readiness on a checklist of external secrets
  to rotate.
- **Counts come from the dump's own snapshot** (`pg_export_snapshot` and `pg_dump --snapshot`), so concurrent
  ingests can't fail a valid dump.
- **Restore stages, validates, and rolls back by itself** when the restored server doesn't pass its check.
- **The manifest is encrypted and the set is signed** by a host key whose public half the operator keeps.
  Encrypting the manifest alone would not authenticate it: age recipients are public, so anyone holding them
  can make a set that decrypts cleanly.
- **Retention modes are named per cloud**, with what each does and doesn't protect against; `locked` is
  opt-in and irreversible.
- **Targets are rclone named remotes**: the reserved `cloud` remote for the VM's own bucket, the operator's
  remotes from a secret.

Second review:

- **Health and readiness are separate.** The restore rolls back on application health only; readiness adds
  the rotation checklist and a recent successful backup, and gates the ready marker. The bootstrap and every
  restore run a backup at once, so a fresh server is ready without waiting a night.
- **SFTP destinations use OpenSSH's `internal-sftp`**, with remove, rename and attribute changes refused and
  files created read-only, and rclone writing in place. `rrsync` (an rsync endpoint) could not take an SFTP
  upload, and `-wo` would not have stopped a delete or overwrite.
- **The per-run dump check reads the whole archive** (`pg_restore --file=/dev/null`), and is described as a
  read check; the weekly scratch restore is the proof that a dump loads.

Third review:

- **The SFTP block uses only upstream `sftp-server` options.** `-m` is not an upstream option and is
  gone. An allowlist (`-p`) of request types without `read`, `readdir`, `remove`, `rename`, `mkdir` or
  `setstat`, and `-u 0777` so every file is created mode `0000`, give create and write while refusing read,
  delete and overwrite, at the protocol and at the file system. rclone pushes flat file names in place.
  `check-sftp-target.sh` proves the four operations against each destination's own OpenSSH version.

## Changes during implementation

- **Scope of the first PR: Phases 1 and 2**, and the Terraform variables they need. `backup_retention_mode`,
  `snapshot_schedule` and `restore_from` (Phase 3) change the durable bucket roots and want a real apply per cloud, so
  they come in their own PR. Until then the `<cloud>/backups/` buckets keep versioning and the 90-day lifecycle only.
- **The operator tools live in `infra/teammind/operator/`** (`teammind-unpack.py`, `teammind-pull.sh`), and the SFTP
  check is `bootstrap/teammind-check-sftp.sh`, installed on the server as `teammind-check-sftp`, since it runs there.
  No PowerShell twin of the pull: Windows runs `teammind-pull.sh` in WSL (rsync isn't native to Windows).
- **`teammind-backup`, `teammind-restore` and `teammind-check-sftp` are installed from the checkout**, not user data:
  user data is at 13.3 KB gzipped of the 15 KB the CI allows, and the checkout is pinned by its commit.
  `olyvr_source_commit` must therefore include them; the bootstrap says so when it doesn't.
- **The signing key's public half is printed, not output by Terraform**: Terraform can't read a file the VM made
  (and a key Terraform made would sit in its state). The bootstrap prints the `allowed_signers` line, the readiness
  check shows it, and the output `signing_key_command` reads it from `/var/lib/olyvr/backup-signer`.
- **Readiness uses `backup_max_age_hours` (default 26)** rather than computing 1.1 × the cron interval.
- **`OLYVR_VAULT=file`** is set in `olyvr.env`, so the vault key is always `state/credential.key` and is in the set.
- **The restore leaves the extension's entries out of `pg_restore`**: the scratch database creates `vector` itself,
  and `COMMENT ON EXTENSION vector` fails for any role but its owner, which with `--exit-on-error` failed every
  restore. The restore script on `main` before this change had the same flags and, without `--exit-on-error`, ended
  with "errors ignored on restore: 1" and a non-zero exit, so it refused every dump.
- **Tested in an Ubuntu 24.04 container** with PostgreSQL 16 and pgvector, age, rclone 1.75.2 and OpenSSH 9.6p1, against
  a stand-in for the Olyvr API: dumps during continuous ingests pass their count check; a truncated dump fails the
  archive read (and passes `--list`); a set with a swapped manifest, a swapped payload or an unknown signer is refused;
  a full restore brings back the rows and the state and keeps the host's port and domain; a restore whose settings make
  the server unhealthy rolls back to a healthy server; `--sanitize` deletes the vault rows, revokes the tokens and holds
  readiness until `--rotation-done`; the SFTP block passes `teammind-check-sftp`; the pull fetches only finished sets
  and its key gets no shell. Not yet run: a real apply on any cloud, so the `cloud` remote's write-only push through
  each cloud's identity is untested.

