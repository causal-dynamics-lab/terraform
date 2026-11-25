# Plan: Terraform for a new TeamMind server (GCP, AWS, Azure)

> Written while this lived in the Olyvr repository as `infra/teammind/`; it is now `olyvr-teammind/` in this one.
> Source mode (the VM fetching commits with a GitHub token) has since been removed: a server installs only from a
> staged bundle. Paths and details below are as they were.

**Status:** Approved 2026-10-30; implemented in `infra/teammind/` (see "Changes after approval" at the end).
Applied on AWS on 2026-10-30 (from `infra/teammind/`, local state) and on Google Cloud on 2026-11-20 from
`olyvr-teammind/gcp` with remote state, for two servers (`engineering-teammind`, `compliance-teammind`). Azure not yet.
For how to run it today, follow `../README.md`, not this plan.
**Related (in the olyvr repo):** `docs/plans/teammind-dogfood1-postgres-deploy.md` (the existing VM, done by hand),
`docs/plans/teammind-memory-server-postgres.md` (the code), `rebuild/docs/server-mode.md` (design).

One `terraform apply` launches a VM in the chosen cloud and, inside it, installs PostgreSQL with
pgvector, installs Olyvr headless with the memory server on PostgreSQL, sets up TLS for the gate,
and prints the TeamMind URL. The apply does not return until the VM reports ready, or fails
with the bootstrap's last log lines: a VM the cloud created is not a server until the bootstrap
has finished. The dogfood plan did all of this by hand on `olyvr-memory`; this is the
same result from code, for the next server.

## What the result looks like

```
infra/teammind/
├─ README.md                 how to run it, variables, what comes out, how to get the token
├─ bootstrap/
│  ├─ bootstrap.sh           the whole in-VM setup, cloud-agnostic, idempotent (re-runnable)
│  ├─ olyvr.service          systemd unit
│  ├─ olyvr-memory.logrotate
│  └─ teammind-check.sh      smoke test: /health, /collections, storage_backend == pgvector
├─ gcp/                      root module: main.tf, variables.tf, outputs.tf, versions.tf
├─ aws/                      same
└─ azure/                    same
```

Three root modules, not one with a `cloud` switch: Terraform can't pick providers conditionally,
and each cloud's VM, firewall, address and DNS resources are different enough that a shared module
would be mostly `count = var.cloud == "gcp" ? 1 : 0`. What is shared is the part that matters:
`bootstrap/` is used by all three. The user data is a cloud-init file rendered with `templatefile()`
that writes `/etc/olyvr/bootstrap.env` (names, URLs, digests, switches) and `bootstrap.sh` itself
(`write_files`, gzip + base64: a few KiB, and the repo is private, so nothing fetches it), then
runs it. AWS caps raw user data at 16 KiB; the script fits with room, and nothing larger or
secret ever goes in it (see "Variables").

| Cloud | VM | Address | Firewall | DNS (optional) |
| --- | --- | --- | --- | --- |
| GCP | `google_compute_instance`, e2-standard-2, Ubuntu 24.04 LTS, 50 GB pd-balanced | `google_compute_address` | `google_compute_firewall`: 22 from `admin_cidrs`, 80 (ACME only), `gate_port` from `reader_cidrs` (required; `0.0.0.0/0` only with `allow_public_readers`) | `google_dns_record_set` when `dns_zone` is set |
| AWS | `aws_instance`, t3.large, Ubuntu 24.04 AMI (SSM parameter), 50 GB gp3 | `aws_eip` | `aws_security_group` | `aws_route53_record` |
| Azure | `azurerm_linux_virtual_machine`, Standard_B2ms, Ubuntu 24.04, 50 GB | `azurerm_public_ip` (static) | `azurerm_network_security_group` | `azurerm_dns_a_record` |

Sizes match the dogfood VM (2 vCPU, 8 GB), which is known to hold Olyvr, the memory API and a
1 GB PostgreSQL. All three are variables.

## Variables (same names in all three roots)

| Variable | What |
| --- | --- |
| `name` | resource prefix, default `teammind` |
| `olyvr_appimage_url` | the Linux AppImage of the release to install (beta or stable; never a dev build, it signs in against dev) |
| `memory_release` | `OLYVR_MEMORY_RELEASE`, pinned, default the build's own |
| `memory_source` | see "Open question 1": how the memory API's source gets onto the VM; a full commit SHA, never a tag |
| `olyvr_appimage_sha256`, `memory_source_sha256` | required; the bootstrap verifies both downloads before unpacking |
| `domain` | DNS name for the gate; empty means IP only |
| `dns_zone` | the cloud's managed zone to put the A record in; empty means you add the record yourself |
| `tls_mode` | `letsencrypt` (needs `domain` **and** `dns_zone`), `self_signed` (the gate's own certificate, readers pin it), `provided` (`tls_secret`: the name of an existing secret holding the PEM pair; never the PEM itself) |
| `acme_email` | for Let's Encrypt |
| `gate_port` | default 8013, as dogfood; 443 works too |
| `admin_cidrs`, `reader_cidrs` | who may reach 22 and the gate; neither has a default, and `0.0.0.0/0` in `reader_cidrs` is refused at plan time unless `allow_public_readers = true` |
| `ssh_user`, `ssh_public_key` | the admin login the VM gets: user name (default `ubuntu`) and the public key put in its `authorized_keys` on all three clouds (no OS Login, no AWS key-pair name: one mechanism, so the readiness check can rely on it) |
| `ready_check`, `ready_timeout`, `ready_private_key_file` | the readiness check (below): on by default, 30 minutes, and the path of the private key matching `ssh_public_key` **on the machine running Terraform**; empty means ssh-agent must hold it. Terraform reads the path only, never the key |
| `llm_base_url`, `llm_model`, `llm_key_secret` | the model the memory API reasons with, written as `OLYVR_MODEL_BASE`, `OLYVR_MODEL`, and `OLYVR_MODEL_KEY` read from the named secret (see "Open question 3") |
| `source_token_secret` | the name of the secret holding the read-only token for the memory API's source |
| `backup_bucket` | an **existing** bucket the nightly dumps are copied to; the root module doesn't create it (see "Backups") |
| `machine_type`, `disk_gb`, `region`/`zone`, cloud project/account ids | per cloud |

**No secret goes through Terraform.** `sensitive` only hides a value from output; it is still in
the state file and, when templated, in the instance's user data, which anyone with read access to
the project can fetch. So:

- Secrets made on the VM (the PostgreSQL password, `OLYVR_SESSION_TOKEN`, the reader token) are
  generated by `bootstrap.sh` and kept in `/etc/olyvr/` (mode 600).
- Secrets you supply (the LLM key, the source download token, a provided TLS pair) live in the
  cloud's secret store (Secret Manager, Secrets Manager, Key Vault) **before** the apply. Terraform
  takes only their names, and gives the VM an identity (service account, instance profile, managed
  identity) allowed to read exactly those. The bootstrap reads them with `curl` against the cloud's
  REST API, authenticated with a token from the instance metadata service (GCP:
  `metadata.google.internal` → Secret Manager `:access`; AWS: IMDSv2 → SigV4 to Secrets Manager, done
  with the `aws` CLI since SigV4 by hand is not worth it; Azure: IMDS → Key Vault `GET …/secrets`),
  into `/etc/olyvr/`, mode 600, and nothing else. So the only CLI the bootstrap needs is `aws`, and
  only on AWS, where the cloud-specific stub installs it (`awscli` v2 from the official zip, with
  its published digest checked) before the shared script runs. GCP's image has `gcloud`, and Azure's
  has nothing we rely on; the shared script never assumes a CLI is there.
- User data holds only names, URLs, digests and switches.

## Outputs

| Output | |
| --- | --- |
| `teammind_url` | `https://<domain or ip>:<gate_port>`, what readers paste as the TeamMind address |
| `public_ip` | for the A record when `dns_zone` is not managed here |
| `ssh` | the ssh command |
| `token_command` | `ssh … sudo cat /etc/olyvr/teammind-token`: the reader token, shown once by Olyvr and kept there by bootstrap |
| `backup_bucket` | where the nightly dumps are |
| `status_command` | `ssh … sudo teammind-check` |

**Readiness.** Each root ends with a `terraform_data` resource with `triggers_replace = [vm.id]`
(not `depends_on`, which only orders: a replaced VM must replace the check too, or the new VM is
never checked) whose `local-exec` provisioner polls the VM over ssh for `/var/lib/olyvr/teammind-ready`, bounded by
`ready_timeout` (default 30 minutes; the venv build is most of it). When the marker appears it
prints the URL; when `/var/lib/olyvr/teammind-failed` appears, or the timeout runs out, it prints
the tail of `/var/log/teammind-bootstrap.log` and fails the apply. A failed apply leaves the VM
for inspection; `apply` again re-runs only the check. The ssh polling runs from the machine running
Terraform as `ssh_user`, with `ready_private_key_file` (or the agent), and `-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<file>`, the file being one of
its own under `.terraform/` that the check deletes and recreates for each VM: `accept-new` is what
lets a non-interactive client take the first key without a prompt (the default asks, and a
provisioner can't answer), and the fresh file is what lets a replacement VM on the same static
address present a new key without being refused; it needs that machine's address in `admin_cidrs`; a public key alone can't authenticate a
client. `ready_check = false` turns it off for a pipeline that can't ssh, and then the contract is
"apply provisions, `status_command` tells readiness".

The token is not a Terraform output: it would sit in plain text in the state file. Phase 6 has
the bootstrap write it to the secret store instead.

## What `bootstrap.sh` does, in order

It runs once from cloud-init as root, logs to `/var/log/teammind-bootstrap.log`, and leaves a
marker per step so a rerun (or a manual `sudo bootstrap.sh`) skips what is done.

1. **Packages:** `postgresql-16`, `postgresql-16-pgvector`, `certbot`, `jq`, `curl`, `libfuse2` is
   not needed (the AppImage is extracted, not run).
2. **PostgreSQL:** `shared_buffers = 512MB`, `work_mem = 16MB`, `listen_addresses = localhost`.
   Role `teammind`, database `teammind`, `CREATE EXTENSION vector`. Password from
   `openssl rand -hex 24` (base64 would put `/` and `+` into `DATABASE_URL`), written to `/etc/olyvr/pg.env`. Nightly `pg_dump -Fc` to
   `/var/backups/teammind`, keeping a week, as the dogfood plan's Phase 5, **and copied the same
   night to `backup_bucket`** (`gcloud storage cp` on GCP, `aws s3 cp` on AWS, and a `curl -X PUT` with a
   metadata token on Azure Blob, with the VM's identity allowed to write and nothing else; the
   cloud stub writes a one-line `backup-upload.sh` the shared cron calls). The bucket must exist before the
   apply and is **not** in the server's root: `prevent_destroy` doesn't skip a resource, it refuses
   the whole destroy, so a bucket in the same root would make `terraform destroy` fail rather than
   spare the dumps. It is made once per environment by the small durable root
   `infra/teammind/<cloud>/backups/` (bucket, versioning, 90-day retention, encryption with the
   cloud's managed key, `prevent_destroy`), and the server root only grants its VM's identity
   write access to it.
   A dump on the same disk as the database is not a backup: a disk failure, a VM replacement or a
   `destroy` takes both.
3. **Olyvr, headless:** user `olyvr`, AppImage downloaded, checked against
   `olyvr_appimage_sha256` (a mismatch stops the bootstrap and removes the file; a tag or a URL is
   not an integrity check, their contents can change) and extracted with `--appimage-extract`, `resources/backend` and `resources/workspace` copied to
   `/opt/olyvr/app`, the installed version read from `app.asar` and logged. `/etc/olyvr/olyvr.env`
   with `OLYVR_SESSION_TOKEN`, `OLYVR_FEATURE_MEMORY_SERVER=1` (the flag is off by default, and
   without it `/api/memory-server` is a 404), `OLYVR_REQUIRE_ACCOUNT=0` (the account middleware
   lets only `/api/account…` and `/api/health` through before a sign-in, and this host never signs
   in), `OLYVR_MEMORY_RELEASE`, the memory source override, and `OLYVR_MODEL_BASE`,
   `OLYVR_MODEL_KEY`, `OLYVR_MODEL`. `olyvr.service` enabled and started; wait for
   `GET http://127.0.0.1:9420/api/health` (the route has the `/api` prefix).
4. **Memory server storage:** `state/memory/server.env` written **as `olyvr`** (`install -o olyvr -m 600`,
   not root-owned and chmod'ed: the check refuses a file another user owns, and the API then stays
   on ChromaDB):
   `MEMORY_BACKEND=pgvector`, `DATABASE_URL=postgresql://teammind:…@127.0.0.1:5432/teammind`,
   `PG_POOL_SIZE=8`. Written before the first install, so there is never a ChromaDB phase and
   nothing to re-send.
5. **TLS:**
   - `letsencrypt`: needs `dns_zone`, so the same apply made the A record for the static address
     before the VM (the address is a resource of its own, created first; the record points at it;
     the VM comes last). The bootstrap waits until `domain` resolves to this VM's address (up to
     15 minutes for propagation), then `certbot certonly --standalone` on port 80; copies the pair
     to `/etc/olyvr/tls/` readable by `olyvr`; a renewal deploy hook copies again and re-saves the
     pair through the local API, which restarts the gate with the new files. Without `dns_zone`
     the roots refuse `letsencrypt` at plan time (a `validation` block): the operator would learn
     the address only from the apply, and cloud-init would time out before the record exists. For
     a zone Terraform can't manage, the documented route is two applies: `tls_mode = self_signed`
     first, add the record by hand, then switch to `letsencrypt` and run `sudo bootstrap.sh` on the
     VM (see "Rerun").
   - `provided`: read the pair from the secret `tls_secret` names, into `/etc/olyvr/tls/`.
   - `self_signed`: nothing; the gate makes its own.
6. **Memory server, through the local API** (`POST /api/memory-server` with the session token),
   not by writing `config.json` by hand, so the same checks as Settings → Server run (certificate
   and key match, the domain is a name on the certificate):
   `save {enabled, shared, port, domain, cert_file, key_file}` → `install` (with a source checkout
   this only builds the venv, several minutes; poll `state()["install"]`) → `start` → wait for
   `/health` on the memory API to say `pgvector` **and** for `GET /api/memory-server` to show the
   model attached (`admin.llm()` runs `discover()` against `OLYVR_MODEL_BASE`; if that endpoint is
   down or doesn't list `OLYVR_MODEL`, the server starts with no model and answers by keywords
   only, which `pgvector` alone would not reveal) → `token {slot: primary}` → write the token to
   `/etc/olyvr/teammind-token`.
7. **Housekeeping:** logrotate for `server.log`, `teammind-check` installed in `/usr/local/bin`,
   marker `/var/lib/olyvr/teammind-ready`, and a last line in the log with the URL.

**Rerun.** Each step's marker holds a digest of the inputs it used. On a rerun (`sudo
bootstrap.sh`, after editing `/etc/olyvr/bootstrap.env` or a secret) a step whose digest changed
is redone, with a defined action, because a changed input otherwise leaves the old thing running:

| Step | Inputs in the digest | When changed |
| --- | --- | --- |
| Olyvr | AppImage URL and sha256 | stop `olyvr`, move `/opt/olyvr/app` aside, extract again, start (the dogfood plan's Phase 2) |
| Memory source | source URL, sha256, `memory_release` | stop the memory server, unpack again, **remove `state/memory/venv`** and `install` again: `install` skips `uv sync` once the venv's python exists, so a new source with the old venv would run with the old dependencies |
| Model | base, model, the key's secret version | rewrite `olyvr.env`, `systemctl restart olyvr`: the memory process gets its model env only when it starts |
| TLS | mode, domain, ACME email, the provided pair's secret version | run certbot or read the secret again, then `save` the pair through the local API, which stops and restarts the gate with the new files |
| PostgreSQL, tokens | none: never redone | the password and the tokens are made once; rotating a token is `token` through the local API, not a rerun |

Phase 1's test list includes one rerun per row. A step whose digest is unchanged is skipped.

Everything is the dogfood plan's Phases 1, 3, 5 in script form, minus the parts that only exist
because that VM already had data (snapshot, the re-share, the beta upgrade in place).

## Open questions (decide before Phase 1)

1. **How the memory API source reaches the VM.** Olyvr normally downloads the pinned release
   from the update service, which hands it out only to a **licensed, signed-in** Olyvr
   (`_install_source` needs a licence token). A headless VM has no sign-in. Dogfood got round
   this with a checkout at `/opt/olyvr/reasonara-memory` and `OLYVR_MEMORY_SOURCE_DIR`; with a
   checkout, `install` only builds the venv and needs no licence. Options:
   - **(A) Checkout, recommended for now.** Variable `memory_source` = a GitHub archive URL of
     `xfabric-sec/reasonara-memory` at the **full commit SHA** of the release, with
     `memory_source_sha256` of that archive, and a read-only **fine-grained PAT** (Contents: read on that one repository; a deploy
     key is an ssh key and can't fetch an archive over HTTPS) in the secret `source_token_secret`
     names. Bootstrap verifies the digest, then unpacks it to
     `/opt/olyvr/reasonara-memory`. This keeps the integrity rule the built-in installer has
     (`server-mode.md`: every download checked against a SHA-256 before it is unpacked or run),
     which the checkout route would otherwise bypass.
   - **(B) A service sign-in for headless hosts** (account API change, so `licence()` on the VM
     is a real licence and the built-in download works). Right, but not this plan.

   A licence token handed in as a variable was considered and dropped: `install` takes the
   licence from the app's own signed-in account (`admin.py`, `self.licence()`), not from the
   request, so there is no supported way to pass one in, and it would be a secret in Terraform.
2. **The headless backend and the account: answered.** The account middleware
   (`onboarding/mount.py`) returns 401 for everything but `/api/account…` and `/api/health` until a
   sign-in, so with the default `OLYVR_REQUIRE_ACCOUNT=1` the bootstrap's `save`, `install`, `token`
   and the certbot deploy hook all fail. The bootstrap sets `OLYVR_REQUIRE_ACCOUNT=0` and
   `OLYVR_FEATURE_MEMORY_SERVER=1`. This host has no account, so no "reachable from the internet"
   probe either; a cloud VM doesn't need it, the firewall is the truth.
3. **Which model the memory API uses.** Retrieval reasoning needs one: `admin.llm()` takes
   `models.conf()` and `llm_env()` maps it to `GATEWAY_LLM_URL`, `GATEWAY_LLM_API_KEY`,
   `GATEWAY_MINI_MODEL` for the memory process. Setting `GATEWAY_*` in `olyvr.env` does nothing (the
   child's env is built from scratch). What works is `OLYVR_MODEL_BASE`, `OLYVR_MODEL_KEY`,
   `OLYVR_MODEL`, which the resolver reads. Still to check on dogfood: which provider and model it
   runs with, so the variables' defaults match.
4. **Port 443 or 8013.** 8013 keeps parity with dogfood and the Confluence setup guide; 443 needs
   no port in the URL and passes strict office firewalls. Default 8013, variable.

## Phases

| Phase | Work | Done when |
| --- | --- | --- |
| 0 | Answer open questions 1, 3 and 4: read dogfood's `olyvr.env` and model config, pick (A) or (B) | decisions noted at the top of this file |
| 1 | `bootstrap/bootstrap.sh` + unit files, run **by hand** on a bare Ubuntu 24.04 VM in `olyvrdev` (`gcloud compute instances create`, scp, run) | `teammind-check` passes; a laptop connects, searches, gets citations; `sudo reboot` keeps everything; running the script again changes nothing; `dmesg` shows no OOM kill during the first `uv sync` (torch is the heaviest step, and this VM has less free memory than dogfood had when it was already installed; if it is killed, add swap or a bigger size for the build) |
| 2 | `gcp/backups/` (the bucket) and `gcp/`: VM, static address, firewall, DNS, service account with access to the named secrets and the bucket, the readiness check; `tls_mode = self_signed` on one VM, then `letsencrypt` with a `dns_zone` on a **fresh** apply | `terraform apply` from empty to a working URL in one go, and an apply with a broken AppImage digest **fails** with the log tail; a `-replace` of the VM passes the check again; `teammind-restore.sh` on a dump fetched from the bucket gives a working server; `destroy` of the server root succeeds and the bucket keeps that night's dump |
| 3 | `aws/` root module, same bootstrap | same test on an AWS account |
| 4 | `azure/` root module | same test |
| 5 | `infra/teammind/README.md`; CI job `terraform fmt -check`, `validate`, `tflint` for the three roots; link from `infra/gcp/README.md` and the Confluence setup guide | PR merged |
| 6 (later) | reader token written to the secret store by the bootstrap (so no ssh is needed to read it); `restore_from` a dump; dev-track builds against the dev environment | separate PRs |

Phase 1 is the real work and the only risky one; Phases 2 to 4 are each a day of Terraform around
the same script. Phase 2 before 3 and 4 because dev's GCP project exists and the team knows it.

## Testing

- `terraform validate` and `tflint` in CI for each root (no cloud credentials needed).
- `bootstrap/teammind-check.sh <url> <token>` from a laptop: `GET /health` 200,
  `GET /collections` 200 with the token and 401 without, `POST /retrieve` of a nonsense word returns
  an empty hit list; and on the VM, `curl 127.0.0.1:18541/health` says `pgvector`.
- Per cloud, once by hand: apply, check, destroy, in a throwaway project/account. Not automated:
  a VM plus a venv build takes 15 minutes and real money.
- Replace the VM once (`terraform apply -replace=<vm>`): the readiness check runs again and
  passes against the new host key.
- **Restore, once, on GCP (Phase 2):** after a dump has reached the bucket, fetch it with the
  operator's own credentials and scp it to the VM (the VM's identity can only write to the bucket;
  it gets no read access, not even temporarily: a server that can read the bucket can read every
  other server's dumps). Then create a fresh database on the VM, `pg_restore` the dump into it,
  point `server.env` at it, restart `olyvr`, and run `teammind-check` plus one search with
  citations. The restore steps go into `bootstrap/teammind-restore.sh <dump file>`, which takes
  that local file, so the outage procedure is the tested one; the README gives the fetch and scp
  commands. A backup nobody has restored is a hope, not a backup.

## Rollback and rerun

- `terraform destroy` removes the VM, address, firewall and DNS record. The database goes with the
  disk; the dumps in `backup_bucket` stay (the bucket belongs to the `<cloud>/backups/` root, which nothing
  here destroys). A new server is
  restored with `bootstrap/teammind-restore.sh <dump file>` after the bootstrap, the dump fetched
  from the bucket by the operator and scp'd in (tested in Phase 2;
  a `restore_from` variable that runs it during the bootstrap is Phase 6).
- A failed bootstrap leaves the VM up with the log in `/var/log/teammind-bootstrap.log`; fix and run
  `sudo /opt/olyvr/bootstrap.sh` again. No step is destructive on rerun.
- `terraform apply` with a changed `olyvr_appimage_url`, `tls_mode`, `domain`, `memory_source` or
  model variable **does not** change a running server: cloud-init reads user data once. Either
  replace the VM, or edit `/etc/olyvr/bootstrap.env` on it and run `sudo bootstrap.sh`, whose
  digests redo the steps whose inputs changed (table under "Rerun"). An upgrade is the Olyvr row.

## Not in scope

- The 307 id-encoding bug in `TeamMindReader.content`: tracked on the dogfood plan. Readers hit
  it whatever server they talk to, so it wants fixing, but it doesn't change this plan.
- Migrating dogfood's existing data: that is the other plan.
- A managed database (Cloud SQL, RDS, Flexible Server): PostgreSQL on the VM is enough for one
  team and is what the code was tested with. Managed is a later variable if a customer needs it.
- Multiple readers' management, monitoring and alerting beyond `teammind-check`.

## Changes after approval

- **No AppImage: the VM runs Olyvr from a source checkout.** *(Superseded: the AppImage came back as the Release
  workflow's `olyvr-linux` artifact, and a server now installs only from a bundle staged by
  `operator/teammind-stage.sh`; `olyvr_source_commit` and source mode are gone.)* #504 (2026-10-29) stopped building Linux
  installers, so `olyvr_appimage_url` and its digest are gone. The bootstrap fetches `olyvr_source_commit`
  (a full SHA; git refuses content that doesn't hash to it, so no separate sha256) with the same PAT as
  the memory source, runs `uv sync --frozen --no-dev --python 3.12` in `rebuild/`, and the service runs
  `scripts/backend-entry.py` from that venv with `OLYVR_RESOURCE_ROOT` at the checkout. The memory
  source is fetched the same way, by commit, so `memory_source_sha256` is gone too.
- **Secrets and backups are functions in the shared script, keyed on `CLOUD`**, rather than a one-line
  script per cloud stub: `read_secret` and the upload in `teammind-backup.sh` switch on the cloud and use
  `curl` with a metadata token (GCP, Azure) or the `aws` CLI, which the packages step installs on AWS only.
- **The scripts ride in user data as plain `write_files` text**, gzipped by AWS's `user_data_base64`;
  8.5 KB gzipped, checked in CI against a 15 KB ceiling.
- **Phase 0, Q3 is still open:** the model variables have no defaults; the README says what they need.
