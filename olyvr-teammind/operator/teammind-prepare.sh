#!/usr/bin/env bash
# Everything before a TeamMind server's `terraform apply`, from one settings file (teammind.conf.example):
#
#   operator/teammind-prepare.sh gcp/<name>.conf
#
# Checks your tools and cloud login, turns on the Google Cloud APIs, makes the state bucket, writes the backend
# settings, applies the backups root (the backup bucket), makes the age keys, makes the bundle bucket and stages the
# bundle, puts the model key in the secret store and checks the model, writes <cloud>/<name>.tfvars, and runs
# `terraform init` for the server. With letsencrypt and DNS kept elsewhere, it also creates the server's address
# first, so the A record can be added before the apply. It prints the apply to run next, then teammind-finish.sh.
#
# Safe to rerun: it skips what exists, and restages the bundle only when MEMORY_RUN or OLYVR_RUN changed.
set -euo pipefail
# shellcheck source=teammind-conf.sh source-path=SCRIPTDIR
. "$(dirname "$0")/teammind-conf.sh"

need terraform gh age-keygen curl jq dig
case $CLOUD in gcp) need gcloud ;; aws) need aws ;; esac

# ---------- cloud login ----------
say "Checking the $CLOUD login"
if [ "$CLOUD" = gcp ]; then
  gcloud auth print-access-token >/dev/null 2>&1 || die "run: gcloud auth login && gcloud auth application-default login"
  gcloud auth application-default print-access-token >/dev/null 2>&1 \
    || die "Terraform needs application-default credentials: gcloud auth application-default login"
  gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null || die "can't read project $PROJECT"
else
  aws sts get-caller-identity --query Arn --output text || die "run: aws sso login --profile <profile>, and export AWS_PROFILE"
fi
gh auth status >/dev/null 2>&1 || die "run: gh auth login (to download the Memory API release)"

if [ "$CLOUD" = gcp ]; then
  say "Turning on the Google Cloud APIs"
  apis="compute.googleapis.com secretmanager.googleapis.com storage.googleapis.com"
  [ -z "${DNS_ZONE:-}" ] || apis="$apis dns.googleapis.com"
  # shellcheck disable=SC2086
  gcloud services enable $apis --project "$PROJECT"
fi

# ---------- buckets ----------
bucket_exists() {
  case $CLOUD in
    gcp) gcloud storage buckets describe "gs://$1" --format='value(name)' >/dev/null 2>&1 ;;
    aws) aws s3api head-bucket --bucket "$1" >/dev/null 2>&1 ;;
  esac
}
make_bucket() {  # a private bucket; $2=versioned
  if bucket_exists "$1"; then echo "bucket $1 exists"; return; fi
  echo "making bucket $1"
  case $CLOUD in
    gcp)
      gcloud storage buckets create "gs://$1" --project "$PROJECT" --location "$REGION" \
        --uniform-bucket-level-access --public-access-prevention
      [ "${2:-}" != versioned ] || gcloud storage buckets update "gs://$1" --versioning ;;
    aws)
      if [ "$REGION" = us-east-1 ]; then aws s3api create-bucket --bucket "$1" --region "$REGION" >/dev/null
      else aws s3api create-bucket --bucket "$1" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null; fi
      aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration \
        BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
      [ "${2:-}" != versioned ] || aws s3api put-bucket-versioning --bucket "$1" \
        --versioning-configuration Status=Enabled ;;
  esac
}

say "Terraform state"
make_bucket "$STATE_BUCKET" versioned
if [ "$CLOUD" = gcp ]; then
  printf 'bucket = "%s"\nprefix = "olyvr-teammind/gcp/%s"\n' "$STATE_BUCKET" "$NAME" > "$ROOT/$NAME.backend.tfvars"
  printf 'bucket = "%s"\nprefix = "olyvr-teammind/gcp-backups/%s"\n' "$STATE_BUCKET" "$BACKUP_ENV" \
    > "$BACKUPS_ROOT/$BACKUP_ENV.backend.tfvars"
  printf 'project  = "%s"\nname     = "%s"\nlocation = "%s"\n' "$PROJECT" "$BACKUP_BUCKET" "${REGION^^}" \
    > "$BACKUPS_ROOT/$BACKUP_ENV.tfvars"
else
  aws_backend() { printf 'bucket       = "%s"\nkey          = "%s"\nregion       = "%s"\nencrypt      = true\nuse_lockfile = true\n' \
    "$STATE_BUCKET" "$1" "$REGION"; }
  aws_backend "olyvr-teammind/aws/$NAME/terraform.tfstate" > "$ROOT/$NAME.backend.tfvars"
  aws_backend "olyvr-teammind/aws-backups/$BACKUP_ENV/terraform.tfstate" > "$BACKUPS_ROOT/$BACKUP_ENV.backend.tfvars"
  printf 'region = "%s"\nname   = "%s"\n' "$REGION" "$BACKUP_BUCKET" > "$BACKUPS_ROOT/$BACKUP_ENV.tfvars"
fi

say "The backup bucket (the backups root; Terraform asks before it changes anything)"
TF_DATA_DIR=$BACKUPS_DATA_DIR terraform -chdir="$BACKUPS_ROOT" init -input=false -reconfigure \
  -backend-config="$BACKUP_ENV.backend.tfvars" >/dev/null
TF_DATA_DIR=$BACKUPS_DATA_DIR terraform -chdir="$BACKUPS_ROOT" apply -var-file="$BACKUP_ENV.tfvars"

# ---------- age keys ----------
say "Backup encryption keys"
if [ ! -f "$AGE_KEY" ]; then
  mkdir -p "$(dirname "$AGE_KEY")" && chmod 700 "$(dirname "$AGE_KEY")"
  age-keygen -o "$AGE_KEY" 2>/dev/null
  echo "made your age key: $AGE_KEY"
fi
AGE_RECIPIENT=$(age-keygen -y "$AGE_KEY")
if [ -z "${BREAKGLASS_RECIPIENT:-}" ]; then
  bg=~/teammind-backup-breakglass.key
  if [ ! -f "$bg" ]; then
    age-keygen -o "$bg" 2>/dev/null
    echo "made the break-glass key: $bg"
    echo "  MOVE IT OFFLINE (a 1Password item), then delete it here and set BREAKGLASS_RECIPIENT in $CONF"
  fi
  BREAKGLASS_RECIPIENT=$(age-keygen -y "$bg")
fi
[[ $BREAKGLASS_RECIPIENT =~ ^age1[0-9a-z]+$ ]] || die "BREAKGLASS_RECIPIENT isn't an age public key"
[ "$BREAKGLASS_RECIPIENT" != "$AGE_RECIPIENT" ] || die "the break-glass key must differ from yours"

# ---------- bundle ----------
say "The bundle"
bundle_vars=$ROOT/$NAME.bundle.tfvars    # what the last staging printed, and from which runs
stage_key="memory_run=${MEMORY_RUN:-} olyvr_run=${OLYVR_RUN:-}"
if [ -n "${ARTIFACTS:-}" ]; then
  [[ -n ${ARTIFACTS_SHA256:-} && -n ${MEMORY_RELEASE:-} ]] || die "with ARTIFACTS, set ARTIFACTS_SHA256 and MEMORY_RELEASE"
  echo "using ARTIFACTS from $CONF"
elif [ -f "$bundle_vars" ] && grep -qxF "# $stage_key" "$bundle_vars"; then
  echo "already staged ($stage_key)"
else
  [ -n "${MEMORY_RUN:-}" ] || die "MEMORY_RUN is required (a Memory API release run id)"
  [ -n "$OLYVR_TRACK" ] || [ -n "${OLYVR_RUN:-}" ] || die "OLYVR_TRACK=\"\" needs OLYVR_RUN (a Release run id)"
  make_bucket "$BUNDLE_BUCKET"
  scheme=$([ "$CLOUD" = gcp ] && echo gs || echo s3)
  args=(--memory-run "$MEMORY_RUN")
  [ -n "$OLYVR_TRACK" ] || args+=(--olyvr-run "$OLYVR_RUN")
  out=$("$HERE/operator/teammind-stage.sh" "${args[@]}" "$scheme://$BUNDLE_BUCKET/teammind" | tee /dev/stderr)
  { echo "# $stage_key"; printf '%s\n' "$out" | grep -E '^(artifacts|artifacts_sha256|memory_release) +='; } > "$bundle_vars"
fi
if [ -z "${ARTIFACTS:-}" ]; then
  val() { sed -n "s/^$1 *= *\"\(.*\)\"$/\1/p" "$bundle_vars"; }
  ARTIFACTS=$(val artifacts); ARTIFACTS_SHA256=$(val artifacts_sha256); MEMORY_RELEASE=$(val memory_release)
  [[ -n $ARTIFACTS && -n $ARTIFACTS_SHA256 && -n $MEMORY_RELEASE ]] || die "can't read $bundle_vars"
fi

# ---------- the model key ----------
say "The model key ($LLM_KEY_SECRET) and the model ($LLM_MODEL)"
read_key() {
  case $CLOUD in
    gcp) gcloud secrets versions access latest --secret "$LLM_KEY_SECRET" --project "$PROJECT" 2>/dev/null ;;
    aws) aws secretsmanager get-secret-value --secret-id "$LLM_KEY_SECRET" --region "$REGION" \
           --query SecretString --output text 2>/dev/null ;;
  esac
}
if ! key=$(read_key) || [ -z "$key" ]; then
  read -rsp "The model endpoint's API key (not echoed; stored as $LLM_KEY_SECRET): " key; echo
  [ -n "$key" ] || die "no key given"
  case $CLOUD in
    gcp) printf '%s' "$key" | gcloud secrets create "$LLM_KEY_SECRET" --data-file=- --project "$PROJECT" ;;
    aws) aws secretsmanager create-secret --name "$LLM_KEY_SECRET" --region "$REGION" \
           --secret-string "file:///dev/stdin" <<<"$key" >/dev/null ;;
  esac
  echo "stored $LLM_KEY_SECRET"
fi
models=$(curl -sf -H @<(printf "Authorization: Bearer %s\n" "$key") "${LLM_BASE_URL%/}/models") \
  || die "the endpoint didn't answer: ${LLM_BASE_URL%/}/models"
unset key
printf '%s' "$models" | jq -e --arg m "$LLM_MODEL" '.data[] | select(.id == $m)' >/dev/null \
  || die "the endpoint doesn't list $LLM_MODEL. It lists: $(printf '%s' "$models" | jq -r '[.data[].id] | join(", ")')"
echo "the endpoint lists $LLM_MODEL"

# ---------- the variables ----------
say "Writing $CLOUD/$NAME.tfvars"
if [ -z "${ADMIN_CIDRS:-}" ]; then
  me=$(curl -sf https://checkip.amazonaws.com | tr -d '[:space:]') || die "can't find this machine's address: set ADMIN_CIDRS"
  ADMIN_CIDRS="$me/32"
  [ "$CLOUD" != gcp ] || ADMIN_CIDRS="$ADMIN_CIDRS 35.235.240.0/20"   # IAP tunnels (gcloud compute ssh --tunnel-through-iap)
  echo "admin_cidrs: $ADMIN_CIDRS (behind WARP the address rotates: list every egress address in ADMIN_CIDRS)"
fi
[ -n "$READER_CIDRS" ] || die "READER_CIDRS is required"
if [ "$TLS_MODE" = letsencrypt ]; then
  [[ -n ${DOMAIN:-} && -n ${ACME_EMAIL:-} ]] || die "letsencrypt needs DOMAIN and ACME_EMAIL"
fi
hcl_list() { local out="" x; for x in $1; do out="$out\"$x\", "; done; printf '[%s]' "${out%, }"; }
tfvars=$ROOT/$NAME.tfvars
[ ! -f "$tfvars" ] || cp "$tfvars" "$tfvars.bak"
{
  echo "# Written by operator/teammind-prepare.sh from $(basename "$CONF"); edit that file and rerun instead."
  echo "name = \"$NAME\""
  if [ "$CLOUD" = gcp ]; then
    printf 'project = "%s"\nregion  = "%s"\nzone    = "%s"\n' "$PROJECT" "$REGION" "$ZONE"
  else
    echo "region = \"$REGION\""
    [ -z "${VPC_ID:-}" ] || echo "vpc_id = \"$VPC_ID\""
    [ -z "${SUBNET_ID:-}" ] || echo "subnet_id = \"$SUBNET_ID\""
  fi
  printf '\nartifacts        = "%s"\nartifacts_sha256 = "%s"\nmemory_release   = "%s"\nolyvr_track      = "%s"\n' \
    "$ARTIFACTS" "$ARTIFACTS_SHA256" "$MEMORY_RELEASE" "$OLYVR_TRACK"
  printf '\nllm_base_url   = "%s"\nllm_model      = "%s"\nllm_key_secret = "%s"\n' "$LLM_BASE_URL" "$LLM_MODEL" "$LLM_KEY_SECRET"
  printf '\ntls_mode   = "%s"\n' "$TLS_MODE"
  [ -z "${DOMAIN:-}" ] || echo "domain     = \"$DOMAIN\""
  [ -z "${ACME_EMAIL:-}" ] || echo "acme_email = \"$ACME_EMAIL\""
  [ -z "${DNS_ZONE:-}" ] || echo "dns_zone   = \"$DNS_ZONE\""
  [ -z "${TLS_SECRET:-}" ] || echo "tls_secret = \"$TLS_SECRET\""
  printf '\nadmin_cidrs            = %s\nreader_cidrs           = %s\nallow_public_readers   = %s\n' \
    "$(hcl_list "$ADMIN_CIDRS")" "$(hcl_list "$READER_CIDRS")" "$ALLOW_PUBLIC_READERS"
  printf 'ssh_user               = "ubuntu"\nssh_public_key         = "%s"\nready_private_key_file = "%s"\n' \
    "$(tr -d '\n' < "$SSH_PUBLIC_KEY_FILE")" "$SSH_PRIVATE_KEY_FILE"
  printf '\nbackup_bucket         = "%s"\nbackup_age_recipients = ["%s", "%s"]\n' \
    "$BACKUP_BUCKET" "$AGE_RECIPIENT" "$BREAKGLASS_RECIPIENT"
  [ -z "${GRAFANA_SECRET:-}" ] || echo "grafana_secret        = \"$GRAFANA_SECRET\""
  printf '\nmachine_type = "%s"\n' "$MACHINE_TYPE"
} > "$tfvars"

# ---------- the server root ----------
say "terraform init for $NAME"
cd "$ROOT"
export TF_DATA_DIR=$SERVER_DATA_DIR
terraform init -input=false -reconfigure -backend-config="$NAME.backend.tfvars" >/dev/null
terraform validate >/dev/null

# letsencrypt with the zone elsewhere: the A record must exist before the VM asks for the certificate.
if [ "$TLS_MODE" = letsencrypt ] && [ -z "${DNS_ZONE:-}" ]; then
  say "The server's address, for the DNS record of $DOMAIN"
  addr=$([ "$CLOUD" = gcp ] && echo google_compute_address.this || echo aws_eip.this)
  terraform apply -var-file="$NAME.tfvars" -target="$addr"
  ip=$(terraform state show -no-color "$addr" | sed -n 's/^ *\(address\|public_ip\) *= *"\([0-9.]*\)"$/\2/p' | head -n1)
  [ -n "$ip" ] || die "can't read the address from $addr"
  if [ "$(dig +short @1.1.1.1 A "$DOMAIN" | tail -n1)" = "$ip" ]; then
    echo "$DOMAIN already points at $ip"
  else
    echo
    echo "ADD THE DNS RECORD FIRST:  $DOMAIN  A  $ip"
    echo "  (for olyvr.ai or cielara-dev.net: a PR to xfabric-sec/dns; it applies on merge)"
    echo "  Check with: dig +short $DOMAIN    then run the apply below."
  fi
fi

cat <<EOF

Ready. Next:

  cd $ROOT
  export TF_DATA_DIR=$SERVER_DATA_DIR
  terraform apply -var-file=$NAME.tfvars          # 15 to 25 minutes; it waits until the server is ready
  $HERE/operator/teammind-finish.sh $CONF
EOF
