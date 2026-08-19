# Every name below is load-bearing: the Cielara deploy references the service
# account and role by deterministic name and does not create them.

locals {
  deployer_sa_id    = "cielara"
  app_sa_id         = "cielara-app"
  deployer_sa_email = "${local.deployer_sa_id}@${var.project_id}.iam.gserviceaccount.com"
  app_sa_email      = "${local.app_sa_id}@${var.project_id}.iam.gserviceaccount.com"

  apis = [
    "secretmanager.googleapis.com",
    "compute.googleapis.com",
    "logging.googleapis.com",
    "iap.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudkms.googleapis.com",
  ]

  deployer_roles = [
    "roles/compute.instanceAdmin.v1",
    "roles/compute.networkUser",
    "roles/compute.networkAdmin",
    "roles/compute.loadBalancerAdmin",
    "roles/iam.serviceAccountUser",
    "roles/compute.securityAdmin",
    "roles/compute.storageAdmin",
    "roles/logging.logWriter",
    "roles/iap.tunnelResourceAccessor",
    "roles/cloudsql.admin",
    "roles/servicenetworking.networksAdmin",
  ]

  # Runtime roles for the VM's own identity: the instance runs as the
  # cielara-app service account (not the deployer, whose key the Cielara
  # control plane holds), so it needs to write its logs/metrics and reach
  # Secret Manager itself.
  app_runtime_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]

  # Frozen at the script-era enabled set: an import block fails hard when the
  # API was never enabled, and APIs added after that era are off on projects
  # adopted earlier. Enabling is idempotent, so newer APIs never need
  # importing — new entries go in `apis` above ONLY, never here.
  migrate_apis = [
    "secretmanager.googleapis.com",
    "compute.googleapis.com",
    "logging.googleapis.com",
    "iap.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]

  # Frozen at the script-era grant set, for the same reason: roles added after
  # that era aren't bound on projects adopted earlier. Creating
  # google_project_iam_member is additive and idempotent, so newer roles never
  # need importing — new entries go in deployer_roles above ONLY, never here.
  migrate_deployer_roles = [
    "roles/compute.instanceAdmin.v1",
    "roles/compute.networkUser",
    "roles/compute.networkAdmin",
    "roles/compute.loadBalancerAdmin",
    "roles/iam.serviceAccountUser",
    "roles/compute.securityAdmin",
    "roles/compute.storageAdmin",
    "roles/logging.logWriter",
    "roles/iap.tunnelResourceAccessor",
    "roles/cloudsql.admin",
    "roles/servicenetworking.networksAdmin",
  ]

  vm_secret_manager_permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.delete",
    "secretmanager.versions.access",
    "secretmanager.versions.add",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
    "secretmanager.versions.enable",
    "secretmanager.versions.disable",
    "secretmanager.versions.destroy",
  ]

  app_kms_permissions = [
    "cloudkms.cryptoKeyVersions.useToSign",
    "cloudkms.cryptoKeyVersions.viewPublicKey",
    "cloudkms.cryptoKeyVersions.list",
    "cloudkms.cryptoKeys.get",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  project = var.project_id
  service = each.value

  # Never switch a shared API off underneath your other workloads.
  disable_on_destroy = false
}

# `google_project_service` returns as soon as the enable operation completes,
# but a freshly enabled API stays unusable in its own backend for a further
# minute or so — creating the keyring straight after enabling cloudkms fails
# with `Error 403: ... API has not been used in project <n> before`. Keyed on
# the API list so a later addition waits again.
resource "time_sleep" "api_propagation" {
  create_duration = "90s"

  triggers = {
    apis = join(",", local.apis)
  }

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "deployer" {
  account_id   = local.deployer_sa_id
  display_name = "Cielara Service Account"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "deployer" {
  for_each = toset(local.deployer_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_project_iam_custom_role" "vm_secret_manager" {
  project     = var.project_id
  role_id     = "cielaraVmSecretManager"
  title       = "Cielara VM Secret Manager"
  description = "Least-privilege secret + version CRUD for the GCP VM SA. No setIamPolicy."
  permissions = local.vm_secret_manager_permissions
  stage       = "GA"
}

resource "google_project_iam_member" "deployer_vm_secret_manager" {
  project = var.project_id
  role    = google_project_iam_custom_role.vm_secret_manager.id
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_service_account_iam_member" "deployer_self_user" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_service_account_iam_member" "deployer_token_creator" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

# Customer-owned Cloud KMS asymmetric key the data plane signs its JWTs with;
# the private key never leaves this project and Cielara cannot read, rotate or
# destroy it. It is bound to the cielara-app SA the VM runs as, never the
# deployer SA whose key the control plane holds. The keyring location must match
# the deploy form's region, which the control plane recomputes from.
resource "google_service_account" "app" {
  account_id   = local.app_sa_id
  display_name = "Cielara App JWT Signing Identity"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_kms_key_ring" "jwt" {
  name     = "cielara-jwt"
  location = var.region
  project  = var.project_id

  depends_on = [time_sleep.api_propagation]
}

# KMS keys cannot be deleted, only their versions disabled/destroyed. Rotation
# is a jwt_key_generation bump (the version resource below); revocation stays
# customer-run:
#   revoke: gcloud kms keys versions disable <N> --keyring cielara-jwt --key jwt-signing --location <region>
resource "google_kms_crypto_key" "jwt_signing" {
  name     = "jwt-signing"
  key_ring = google_kms_key_ring.jwt.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm        = "EC_SIGN_P256_SHA256"
    protection_level = "SOFTWARE"
  }

  # Destroying this key schedules every version for destruction, which stops a
  # live data plane signing within minutes and, once the window lapses, loses
  # the key material forever. The usual way to trigger that by accident is
  # changing var.region: the keyring location is immutable, so terraform plans
  # a replace. Refuse it here — a genuine region move means destroying the
  # deployment first, then consciously deleting this block for one apply.
  lifecycle {
    prevent_destroy = true
  }
}

# The key is born with version 1; each generation past the first is an explicit
# version. The data plane signs with the highest ENABLED version, so a bump
# rotates inside its ~5-minute key cache and a decrement rolls back (the
# dropped version is scheduled for destruction, recoverable inside the KMS
# window). Versions created out-of-band shift the numbering, never the
# behavior.
resource "google_kms_crypto_key_version" "jwt_signing" {
  for_each   = toset([for g in range(2, var.jwt_key_generation + 1) : tostring(g)])
  crypto_key = google_kms_crypto_key.jwt_signing.id
}

resource "google_project_iam_custom_role" "app_jwt_signer" {
  role_id     = "cielaraAppJwtSigner"
  title       = "Cielara App JWT Signer"
  description = "Sign + read public key + list versions on the cielara-jwt signing key. No version create/disable/destroy."
  permissions = local.app_kms_permissions
  project     = var.project_id
  stage       = "GA"

  depends_on = [google_project_service.apis]
}

# Key-resource scope, not project scope: the signer role reaches exactly this
# one key.
resource "google_kms_crypto_key_iam_member" "app_jwt_signer" {
  crypto_key_id = google_kms_crypto_key.jwt_signing.id
  role          = google_project_iam_custom_role.app_jwt_signer.id
  member        = "serviceAccount:${google_service_account.app.email}"
}

# The deployment VM is attached to the cielara-app service account, so its
# runtime needs land here: log/metric writing plus the same Secret Manager
# custom role the deployer uses for provisioning. The deployer's project-scope
# roles/iam.serviceAccountUser (deployer_roles above) is what lets the deploy
# attach the VM to this account.
resource "google_project_iam_member" "app_runtime" {
  for_each = toset(local.app_runtime_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.app.email}"
}

resource "google_project_iam_member" "app_vm_secret_manager" {
  project = var.project_id
  role    = google_project_iam_custom_role.vm_secret_manager.id
  member  = "serviceAccount:${google_service_account.app.email}"
}

resource "google_service_account_key" "deployer" {
  count = var.create_key ? 1 : 0

  service_account_id = google_service_account.deployer.name
}

# Upload this file in the Cielara deploy form. The key also lives in the
# Terraform state — protect the state like a credential (see the README's
# Remote state section).
# storage_url is a Cielara addition on top of the Google key document; GCP
# auth ignores unknown JSON fields.
resource "local_sensitive_file" "key" {
  count = var.create_key ? 1 : 0

  filename = var.key_output_path
  content = jsonencode(merge(
    jsondecode(base64decode(google_service_account_key.deployer[0].private_key)),
    { storage_url = var.state_storage_url },
  ))
  file_permission = "0600"
}
