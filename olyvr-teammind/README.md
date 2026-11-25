# A TeamMind server from Terraform

One `terraform apply` launches a VM on Google Cloud, AWS or Azure and, inside it, installs PostgreSQL 16
with pgvector, runs Olyvr headless (the newest public beta AppImage by default, or a staged bundle's: "The bundle" below) with the memory server on PostgreSQL behind
its gate, sets up TLS, makes the reader token, and prints the TeamMind URL. The apply waits until the VM
reports ready and fails, with the bootstrap log's tail, when it doesn't.

Plan and decisions: [docs/teammind-terraform-setup.md](docs/teammind-terraform-setup.md) (written while this lived in
the Olyvr repository; source mode, which it describes, is gone: a server installs only from a bundle).

```
olyvr-teammind/
├─ bootstrap/            the in-VM setup, shared by the three clouds
│  ├─ bootstrap.sh       every step, idempotent; markers hold a digest of each step's inputs
│  ├─ cloud-init.yaml.tftpl  what the VM boots with: the inputs file and these scripts
│  ├─ olyvr.service, olyvr-memory.logrotate, certbot-deploy.sh
│  ├─ teammind-check.sh  health and readiness
│  ├─ teammind-backup.sh, teammind-restore.sh, teammind-check-sftp.sh   installed from the bundle, not user data
│  ├─ teammind-monitoring.sh  Grafana Alloy: metrics and logs to Grafana Cloud (from the bundle too)
│  └─ wait-ready.sh      the readiness check Terraform runs from your machine
├─ operator/             run on your machine, never on the server
│  ├─ teammind-unpack.py checks a backup set's signature and digests and streams it, decrypted, to teammind-restore
│  ├─ teammind-stage.sh  stages the bundle a server installs
│  └─ teammind-pull.sh   pulls the encrypted sets to a PC or NAS
├─ gcp/  aws/  azure/    one root per cloud; variables.tf, common.tf and outputs.tf are identical copies
│  ├─ backend.tf         where the state lives (backend.hcl.example; see "State")
│  └─ backups/           the durable bucket, its own root, applied once per environment
└─ monitoring/           Grafana Cloud alerts, PagerDuty and the outside checks, for every server (state in GCS)
```

Backups are planned in [docs/teammind-backup-recovery.md](docs/teammind-backup-recovery.md), monitoring in
[docs/teammind-monitoring.md](docs/teammind-monitoring.md).

## State

Every root keeps its state in its cloud's own storage: a GCS bucket (`gcp`), an S3 bucket with `use_lockfile`
(`aws`, Terraform 1.11 or newer), an Azure Storage container read with your Entra ID login (`azure`). Make the
bucket once, versioned and private, copy `backend.hcl.example` to `backend.hcl` (git-ignored) in each root, fill
it in, and initialise with it. Give every server its own key (the server's `name` in it, as the example does) and
every environment's backups root its own: two servers on one key share one state, so applying the second plans to
replace the first's VM.

```bash
cp backend.hcl.example backend.hcl && $EDITOR backend.hcl
terraform init -backend-config=backend.hcl
```

The state holds the VM's user data and resource IDs, never a secret value (those stay in the secret store), but
keep the bucket private all the same. Use a bucket of its own, not the backup bucket.

## Before the first apply

1. **The backup bucket**, once per environment: `cd <cloud>/backups && terraform apply`. It has versioning,
   90-day retention and `prevent_destroy`, in its own root so the server's `destroy` never touches it.
2. **Secrets, in the cloud's secret store** (Secret Manager, Secrets Manager, Key Vault in RBAC mode).
   Terraform takes only their names; the VM's identity reads them. Put the values there first:
   - `llm_key_secret`: the API key of the model endpoint (leave the variable empty for an endpoint without one).
   - `tls_secret` (only for `tls_mode = provided`): the PEM private key followed by the certificate chain.
3. **Backup keys** (see "Backups" below): `age-keygen -o age.key` on your machine, twice (yours, and a break-glass
   copy kept offline); their public halves (`age-keygen -y age.key`) go in `backup_age_recipients`. Keep the private
   keys in the password manager: without one, no backup can be read.
4. **The bundle to run.** `artifacts`, `artifacts_sha256` and `memory_release`, as `operator/teammind-stage.sh`
   prints them ("The bundle", below). The host pins that memory release and is never offered an update.
5. **A model.** `llm_base_url` and `llm_model`: an OpenAI-compatible endpoint that lists that model. The
   bootstrap fails if the memory API comes up without a model, because a server that answers by keywords
   only would otherwise look healthy.
6. **DNS.** `tls_mode = letsencrypt` needs `domain` and `acme_email`. With `dns_zone` (a zone this cloud
   account manages) the apply creates the A record before the VM, and the VM waits for it before asking for a
   certificate. For a zone managed elsewhere, leave `dns_zone` empty: apply with `self_signed`, add the record
   to the printed `public_ip` by hand, then set `letsencrypt` in `terraform.tfvars` and apply (which opens
   port 80 for the ACME challenge), and rerun the bootstrap with the same values (below).
7. **Who may read.** `reader_cidrs` has no default: name the office and VPN ranges readers come from.
   The gate speaks HTTPS only and answers nothing without a valid reader token, but a port open to
   the internet is still that; `allow_public_readers = true` is the explicit opt-in for `0.0.0.0/0`.
   (`OLYVR_REQUIRE_ACCOUNT=0` on the VM concerns the backend's loopback API only, which the firewall
   never exposes; the gate's token check is separate and always on.)
8. **ssh.** `ssh_public_key` goes into `ssh_user`'s `authorized_keys`. The readiness check connects from
   the machine running Terraform with `ready_private_key_file` (or ssh-agent), so that machine's address
   must be in `admin_cidrs`. `ready_check = false` skips it for a pipeline that can't ssh; then the apply only
   provisions, and `status_command` tells readiness.

### Olyvr: the public track or the bundle

`olyvr_track` (default `beta`) makes the VM download Olyvr itself: the newest AppImage of that public track, from
the update service's feed (`https://olyvr.ai/updates/feed/<track>/latest-linux.yml`), checked against the SHA-512 the
feed gives. `stable` follows stable releases. Every rerun of the bootstrap reads the feed again, so a rerun (or a
replaced VM) moves to the track's newest release; `teammind-check` and the end of the bootstrap log print the version
installed. Set `olyvr_track = ""` to pin Olyvr to the AppImage in the bundle instead. Dev builds aren't offered: the
update service hands them only to the Olyvr team's licences.

The memory API and the backup tools come from the bundle either way: the update service hands memory API releases to
licensed Olyvrs only, and the server runs without a licence. With `olyvr_track` set, a bundle without Olyvr is
enough: `teammind-stage.sh --memory-run <id> <dest>` (no `--olyvr-run` or `--appimage`) stages one under
`<dest>/memory-<tag>/`.

### The bundle

The VM installs built files: Olyvr's Linux AppImage (the
`olyvr-linux` artifact of a **Release** run, `release.yml`) and the `linux-x86_64` archive of a
**Memory API release** run (`memory-release.yml`) for the tag `memory_release` names. Stage them with
`operator/teammind-stage.sh` from the two run IDs (or `--appimage` and `--memory` files, with `--track`). It reads
the build's track from the run, adds the backup tools from this folder and a `BUNDLE` file saying what went in,
writes `SHA256SUMS`, uploads `<dest>/<track>-<version>/` and prints the variables:

```bash
olyvr-teammind/operator/teammind-stage.sh --olyvr-run <id> --memory-run <id> s3://<bucket>/teammind
# artifacts        = "s3://<bucket>/teammind/dev-0.1.6-dev.3.…"
# artifacts_sha256 = "<SHA-256 of its SHA256SUMS>"
# memory_release   = "v0.4.0-beta.35"
```

The bootstrap checks `SHA256SUMS` against `artifacts_sha256` and every file against `SHA256SUMS` before unpacking
it, refuses a bundle whose memory release isn't `memory_release`, unpacks the AppImage's `resources/backend` and
`resources/workspace` to `/opt/olyvr/app` (`olyvr.service` runs its `olyvr-backend`), and gives the
memory API the archive as its source. `teammind-check` prints the bundle a server runs. On AWS an `s3://` folder
is read with the VM's identity, which gets `s3:GetObject` on that folder only. On Google Cloud a `gs://` folder is
too, with `roles/storage.objectViewer` conditioned on that folder; the bucket needs uniform bucket-level access, and
the plan fails without it. On Azure an `https://<account>.blob.core.windows.net/<container>/…` folder is read with
the VM's identity too, which gets *Storage Blob Data Reader* on that container (the account is looked up in
`artifacts_resource_group`, by default `backup_resource_group`; staging there needs *Storage Blob Data Contributor*
for your `az login`). Elsewhere use a public `https://` URL. Each root accepts only the schemes its cloud reads. Use a
bucket (storage account) of its own, not the backup bucket: that one expires objects after 90 days, and a rerun or a
replaced VM reads the bundle again.

**Switching builds** (a dev build to a beta, say): run **Release** with that track and stage its run
under the same `<dest>`. On the VM, set the printed `ARTIFACTS` and `ARTIFACTS_SHA256` in
`/etc/olyvr/bootstrap.env` and run `sudo /opt/olyvr/bootstrap.sh`: Olyvr and the memory API are replaced, the
database and the tokens stay. Put the same values in `terraform.tfvars` too, so a replaced VM gets that bundle
(on AWS the VM may read any bundle under `<dest>`; on AWS and Azure a changed user data is ignored rather than
restarting or replacing the VM; on Google Cloud it updates the metadata in place, which a running VM doesn't reread). Or `terraform apply -replace=<the vm resource>` for a fresh VM on it. A dev build talks to the dev services
(dev.olyvr.ai), beta and stable to production's.

## Apply

```bash
cd olyvr-teammind/gcp          # or aws, azure
$EDITOR terraform.tfvars       # the variables in variables.tf and main.tf; tfvars files are git-ignored
terraform init -backend-config=backend.hcl
terraform apply
```

Outputs: `teammind_url` (what readers paste as the TeamMind address), `public_ip`, `ssh`, `token_command`,
`status_command` and `signing_key_command` (this server's backup signing key, as an `allowed_signers` line; the
readiness check prints it too). The reader token is not an output: it would sit in plain text in the state file.
Read it with the printed command (`sudo cat /etc/olyvr/teammind-token`) and hand it out with the URL.
Readers of a `self_signed` server pin its certificate on first use, as ssh does with host keys.

The apply takes 15 to 25 minutes; the memory API's environment (torch and friends) is most of it. Follow
along with `ssh … sudo tail -f /var/log/teammind-bootstrap.log`.

## Per-cloud extras

| Cloud | Extra variables | Identity |
| --- | --- | --- |
| GCP | `project`, `region`, `zone` | a service account: `secretAccessor` on each named secret, `objectCreator` on the bucket. The VM sits in a VPC network of its own, `<name>-vpc` with the subnetwork `<name>-subnet` (the first `/24` of `vpc_cidr`), since the project's `default` network allows ssh from anywhere |
| AWS | `region`; optional `availability_zone`, or `vpc_id` and `subnet_id` for an existing VPC. Without `vpc_id` the server gets a VPC of its own, `<name>-vpc`: one public `/24` subnet routed to an internet gateway, nothing else | an instance profile: `GetSecretValue` on the named secrets, `PutObject` on the bucket. The bootstrap installs the AWS CLI after checking Amazon's signature with the key in `bootstrap/aws-cli.pub.asc` |
| Azure | `subscription_id`, `location`, `key_vault`, `key_vault_resource_group`, `backup_storage_account`, `backup_resource_group`, `dns_zone_resource_group`; optional `resource_group` to put the server in an existing resource group instead of a new one named `name`, and `artifacts_resource_group` for a Blob bundle | a system-assigned identity: *Key Vault Secrets User* on each named secret (not the vault), a custom role on the container that reads and writes blobs but never deletes them, *Storage Blob Data Reader* on a Blob bundle's container. The VM sits in a virtual network of its own, `<name>-vnet` on `vpc_cidr`, with the subnet `<name>-subnet` (its first `/24`) |

Every cloud gives the server a network of its own on `vpc_cidr` (default `10.80.0.0/16`; the server's subnet is its first `/24`), where nothing else runs and its firewall rules are the only way in. On AWS, `vpc_id` uses an existing VPC instead.

Machine sizes that match the dogfood server: `e2-standard-2`, `t3.large`, `Standard_B2ms`.

## Changing a running server

Cloud-init reads user data once, so a changed variable doesn't reach a running VM. Either replace the VM
(`terraform apply -replace=<the vm resource>`; the readiness check runs again), or on the VM edit
`/etc/olyvr/bootstrap.env` and run `sudo /opt/olyvr/bootstrap.sh`. Each step keeps a digest of its inputs
and redoes itself when they change:

| Changed | What the rerun does |
| --- | --- |
| `ARTIFACTS`, `ARTIFACTS_SHA256` | stops Olyvr, unpacks the bundle's AppImage and tools, replaces the memory API's source and venv, starts it |
| `OLYVR_TRACK`, or a newer release on that track | stops Olyvr, unpacks the track's newest AppImage (and the bundle's tools), starts it. A rerun with nothing else changed is how a server updates Olyvr |
| `MEMORY_RELEASE` (with a bundle holding it) | stops the memory API, removes its venv and installs again |
| `LLM_*`, or the key's secret value | rewrites `olyvr.env` and restarts Olyvr (the memory process gets its model when it starts) |
| `TLS_MODE`, `DOMAIN`, `ACME_EMAIL`, or the provided pair's secret | gets the certificate again and re-saves it through the local API, which restarts the gate |
| `GRAFANA_SECRET`, or the secret's value | rewrites `/etc/olyvr/grafana.env` and Alloy's config, restarts Alloy |
| the PostgreSQL password, the tokens | never: made once. Rotate the reader token through the local API (next row) |

A failed bootstrap leaves the VM up with the log in `/var/log/teammind-bootstrap.log`; fix the cause and run it
again. No step is destructive on a rerun.

## Opening the server's Olyvr

The server's Olyvr (Settings, the memory server, its data sources, Insights) answers on the VM's loopback port
9420 only, and by default only to the desktop shell, which a server doesn't have: a browser gets
`401 launch this app through its local desktop shell`. To open it in a browser, give the service the setting
`OLYVR_BROWSER_SESSION=1` in a systemd drop-in of its own, which a later bootstrap run leaves alone, and tunnel to
the port from your machine:

```bash
# on the VM, once
sudo install -d /etc/systemd/system/olyvr.service.d
printf '[Service]\nEnvironment=OLYVR_BROWSER_SESSION=1\n' | sudo tee /etc/systemd/system/olyvr.service.d/browser.conf
sudo systemctl daemon-reload && sudo systemctl restart olyvr

# on your machine
ssh -N -L 9420:127.0.0.1:9420 <ssh_user>@<public_ip>     # or: gcloud compute ssh <vm> -- -N -L 9420:127.0.0.1:9420
# then open http://127.0.0.1:9420/
```

No token is asked for: opening the page starts a session, kept in a cookie. The tunnel is what keeps others out.
The port is never opened in the firewall and the backend still refuses any host but loopback, so with the setting
on, whoever can ssh to the VM (or run a process on it) can open its Olyvr. Leave it off on a server where that is
too many people.

## Day to day, on the VM

| | |
| --- | --- |
| Status | `sudo teammind-check`: readiness, which is health plus a backup within `backup_max_age_hours`, a passing restore check within 8 days and no secret rotation outstanding; exit 0 ready, 2 healthy but not ready (with the reasons), 1 unhealthy. `sudo teammind-check --health`: the backend, storage, model and gate only. From a laptop: `teammind-check https://host:8013 <token> [gate.crt]`; a self-signed gate is pinned by its certificate, fetched from the server when none is given, with the fingerprint printed to compare with the host's pane |
| Logs | `journalctl -u olyvr -f`; the memory API's `/var/lib/olyvr/state/memory/server.log` |
| The local API | `curl -s -H "Authorization: Bearer $(sudo cat /etc/olyvr/session-token)" http://127.0.0.1:9420/api/memory-server` |
| Rotate the reader token | share the secondary first: `… -d '{"action":"token","slot":"secondary"}'`, then regenerate the primary |
| Backups | `/etc/cron.d/teammind-backup` at `backup_schedule`: one encrypted, signed set to `/var/backups/teammind/<set>` (a week) and to every `backup_targets` entry. Status: `/var/lib/olyvr/backup-status.json`. Log: `/var/log/teammind-backup.log`. By hand: `sudo teammind-backup [--verify]` |
| Monitoring | `systemctl status alloy teammind-collect.timer`; Alloy's own UI on `127.0.0.1:12345` (ssh -L); the last check `/run/teammind-check.last`; the metrics it wrote `/var/lib/alloy/textfile/teammind.prom` |
| Certificates | certbot renews by its timer; `/etc/letsencrypt/renewal-hooks/deploy/olyvr.sh` copies the new pair and restarts `olyvr`, since the gate serves the certificate it started with (log: `/var/log/teammind-certbot.log`) |

## Backups

Each run makes one **set**, `teammind-<host>-<UTC time>`: the database dump, the portable state (Olyvr's store with the
reader-token rows, the vault key, the reader token, the memory server's settings and its self-signed pair), and a
manifest, each encrypted with [age](https://age-encryption.org) to `backup_age_recipients`; the manifest is signed with
the server's own key, and `SHA256SUMS` lists the four files. Host configuration (`bootstrap.env`, `pg.env`,
`server.env`, TLS) is not in it: a restore keeps the target's own. The dump and the manifest's row counts come from one
snapshot, the whole archive is read back before upload, and once a week (and on the bootstrap's first run) the dump is
restored into a scratch database and its rows compared.

**Destinations.** `backup_targets` lists `<remote>:<path>` entries, pushed with rclone:

- `cloud:<bucket>/<host>`: this cloud's `backup_bucket`, through the VM's identity, which may create objects and do
  nothing else. The default when `backup_targets` is empty.
- Any other remote: an rclone config section in the secret `backup_remote_secret` names (`[aws_backup] type = s3 …`,
  `[nas_backup] type = sftp …`), with a credential that can write and not read or delete. The name `cloud` is reserved.
  The bootstrap refuses a target whose remote isn't defined, and takes the first backup before it reports ready, so a
  wrong credential fails the apply.
- **An SFTP destination** is OpenSSH's own SFTP server, restricted so the backup user can create and write files and
  nothing else:

  ```
  # /srv/teammind-backups            root:root 755
  # /srv/teammind-backups/incoming   teammind-backup:teammind-backup 700
  Match User teammind-backup
      ChrootDirectory /srv/teammind-backups
      ForceCommand internal-sftp -d /incoming -u 0777 -p open,close,write,fsync,realpath,stat,lstat,fstat,limits
      AllowTcpForwarding no
      AllowAgentForwarding no
      X11Forwarding no
      PermitTTY no
  ```

  Its rclone section sets `shell_type = none`, `disable_hashcheck = true`, `set_modtime = false` and
  `known_hosts_file`; the target is the folder, `nas_backup:/incoming`, and sets land there as flat `<set>.<file>`
  names. Before first use, and after an OpenSSH upgrade there, `sudo teammind-check-sftp nas_backup:/incoming` on the
  server must pass every line (create and write; read, list, overwrite, rename, mkdir and delete refused). Tested with
  OpenSSH 9.6p1 and rclone 1.75.2.
- **A PC or NAS pulls** with `operator/teammind-pull.sh -i <key> teammind-pull@<server> <folder>` from cron or launchd
  (Windows: in WSL). `pull_ssh_public_key` is that key; on the server it may only `rrsync -ro` the sets. The machine
  must be in `admin_cidrs`. Keeps 14 sets plus one a week for 8 weeks; watch `<folder>/.last-success`.

**Alerts.** `backup_ping_url` (healthchecks.io, Better Stack, Cronitor, or self-hosted) gets a ping after each good run
and `<url>/fail` after a bad one, and alerts when pings stop, including when the VM is gone. `teammind-check` reports
not ready when the last good backup is older than `backup_max_age_hours` (26).

## Restore

On your machine, with your own credentials, the age key and an `allowed_signers` file holding each server's
`signing_key_command` line (keep an old server's line while its sets exist):

```bash
rclone copy aws_backup:teammind-backups/<host>/teammind-<host>-<time> ./teammind-<host>-<time>   # or the pull folder
operator/teammind-unpack.py ./teammind-<host>-<time> | ssh ubuntu@<ip> sudo teammind-restore -
```

`teammind-unpack.py` (defaults: `~/.config/teammind/age.key`, `~/.config/teammind/allowed_signers`) refuses a set whose
signature is from no key in your file, whose manifest names another set, or whose files don't match it; it shows the
set's host, time and row counts and asks before streaming. Nothing decrypted is written to your disk. For a folder of
flat SFTP names, give `--set <name>`.

`teammind-restore` stages the database in a scratch database and the state in a folder and checks both (row counts,
the store's integrity and schema, the vault key, the gate pair) while the server keeps running; then it stops Olyvr,
swaps them in (the old ones kept as `teammind_before_<time>` and `<file>.before_<time>`), starts it and waits for
`teammind-check --health`. If that fails it puts everything back and starts the server as it was. On success it takes
a backup and prints what to drop when happy. Options:

- `--db-only`: the database alone. A plain `.dump` file from before sets is restored this way:
  `sudo teammind-restore <file>.dump`.
- `--sanitize`, after a compromise: restore a set from before it. Vault rows are deleted, every restored reader token
  is revoked and new ones are made, and the server stays not ready until each secret in
  `/var/lib/olyvr/rotation-required` is rotated and confirmed with `sudo teammind-restore --rotation-done` (`ssh -t`).
  The marker is written before the sanitized server starts and stays on every failure, a rollback included.
- `--allow-version-skew`: a set made by another Olyvr build is refused otherwise; better, rerun the bootstrap on the
  set's bundle, restore, then upgrade.

## Monitoring

Grafana Alloy on the VM sends its metrics (CPU, memory, disk, network, the `olyvr` and PostgreSQL units, and
`teammind-check`'s result every minute) and its logs (those units' journal, the memory API's `server.log`, the
bootstrap and backup logs) to Grafana Cloud, labelled `teammind_server` = `name`. `monitoring/` makes the alerts,
sends them to PagerDuty, and calls each gate from Grafana's probes. The plan, with the alert list:
[docs/teammind-monitoring.md](docs/teammind-monitoring.md).

**Keys, made by hand, never committed:**

| Key | Where to make it | Where it goes |
| --- | --- | --- |
| Access policy token, scopes `metrics:write` and `logs:write` | Grafana Cloud portal → Access Policies | the `grafana_secret` secret, below |
| Service account token, role Editor | the stack's Grafana → Administration → Service accounts | `grafana_auth` in `monitoring/terraform.tfvars` |
| Synthetic Monitoring access token | the stack's Grafana → Testing & synthetics → Config | `sm_access_token` there |
| PagerDuty Events API v2 integration key | PagerDuty → the TeamMind service → Integrations | `pagerduty_integration_key` there |

**On each server.** Put the connection in the cloud's secret store as one secret, lines of `KEY=value` (the URLs
and IDs are on the stack's Prometheus and Loki *Details* pages in the portal):

```
GRAFANA_METRICS_URL=https://prometheus-prod-….grafana.net/api/prom/push
GRAFANA_METRICS_USER=<Prometheus instance ID>
GRAFANA_LOGS_URL=https://logs-prod-….grafana.net/loki/api/v1/push
GRAFANA_LOGS_USER=<Loki user ID>
GRAFANA_TOKEN=glc_…
```

and set `grafana_secret` to its name; the VM's identity gets read access to it like the others. One secret, not five
variables: each variable costs user data, and AWS caps that at 16 KiB. A running server: apply (for the read
access), add `GRAFANA_SECRET='<name>'` and `NAME='<name>'` to `/etc/olyvr/bootstrap.env`, and rerun the bootstrap.
The bundle must be staged from a checkout that has `teammind-monitoring.sh`.

A hand-built VM (dogfood): copy `bootstrap/teammind-check.sh` and `bootstrap/teammind-monitoring.sh` to
`/usr/local/bin/teammind-check` and `/usr/local/bin/teammind-monitoring`, write the lines above to
`/etc/olyvr/grafana.env` (mode 600) and `TEAMMIND_SERVER`, `CLOUD`, `GATE_PORT` and `DOMAIN` to
`/etc/olyvr/monitoring.env`, then `sudo teammind-monitoring install`. `teammind-check` needs the session token in
`/etc/olyvr/session-token`.

**The alerts.** Once, and again when a server is added:

```bash
cd olyvr-teammind/monitoring
cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars   # git-ignored
cp backend.hcl.example backend.hcl && $EDITOR backend.hcl                   # git-ignored
terraform init -backend-config=backend.hcl && terraform apply
```

`servers` lists the gates to call from outside, keyed by `teammind_server`; the probes in `probes` must get through
the server's `reader_cidrs`. Rules route to the PagerDuty contact point by their own notification settings, so the
stack's notification policies stay as they are. In PagerDuty, give `warning` events low urgency (an event rule on
severity) so only `critical` ones wake someone.

## Destroy

`terraform destroy` in the server root removes the VM, address, firewall, identity and DNS record. The
database goes with the disk; the sets in the bucket and every other destination stay.

## Checks in CI

`.github/workflows/olyvr-teammind.yml`: the three roots' shared files are identical, `terraform fmt`,
`terraform validate` on all seven roots, tflint, shellcheck (bootstrap and operator scripts), `teammind-unpack.py`
compiles, and the cloud-init template renders to YAML under AWS's user-data cap. Applies are by hand: a VM plus a venv build costs real time and money.
