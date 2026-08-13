# Every name below is load-bearing: the Cielara deploy references these
# service accounts and roles by deterministic name and does not create them.

locals {
  deployer_sa_id   = "cielara"
  node_sa_id       = "gke-node-sa"
  app_sa_id        = "cielara-app"
  jwt_signer_sa_id = "cielara-jwt-signer"

  deployer_sa_email   = "${local.deployer_sa_id}@${var.project_id}.iam.gserviceaccount.com"
  node_sa_email       = "${local.node_sa_id}@${var.project_id}.iam.gserviceaccount.com"
  app_sa_email        = "${local.app_sa_id}@${var.project_id}.iam.gserviceaccount.com"
  jwt_signer_sa_email = "${local.jwt_signer_sa_id}@${var.project_id}.iam.gserviceaccount.com"

  apis = [
    "container.googleapis.com",
    "compute.googleapis.com",
    "file.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudkms.googleapis.com",
  ]

  deployer_roles = [
    "roles/container.admin",
    "roles/compute.networkAdmin",
    "roles/compute.loadBalancerAdmin",
    "roles/compute.securityAdmin",
    "roles/cloudsql.admin",
    "roles/servicenetworking.networksAdmin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
  ]

  node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]

  # Frozen at the script-era enabled set, for the same reason as the role lists
  # below: an import block fails hard when the API was never enabled, and APIs
  # added after that era are off on projects adopted earlier. Enabling is
  # idempotent, so newer APIs never need importing — new entries go in `apis`
  # above ONLY, never here.
  migrate_apis = [
    "container.googleapis.com",
    "compute.googleapis.com",
    "file.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ]

  # Frozen at the script-era grant set: an import block fails hard when the
  # binding is absent, and roles added after that era don't exist on projects
  # adopted earlier. Creating google_project_iam_member is additive and
  # idempotent, so newer roles never need importing — new entries go in
  # deployer_roles/node_roles above ONLY, never here.
  migrate_deployer_roles = [
    "roles/container.admin",
    "roles/compute.networkAdmin",
    "roles/compute.loadBalancerAdmin",
    "roles/cloudsql.admin",
    "roles/servicenetworking.networksAdmin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
  ]

  migrate_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]

  app_secret_manager_permissions = [
    "secretmanager.secrets.create",
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.delete",
    "secretmanager.versions.access",
    "secretmanager.versions.add",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
    "secretmanager.versions.destroy",
  ]

  filestore_sweep_permissions = [
    "file.instances.list",
    "file.instances.get",
    "file.instances.delete",
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
  display_name = "Cielara GKE Service Account"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "deployer" {
  for_each = toset(local.deployer_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_service_account" "node" {
  account_id   = local.node_sa_id
  display_name = "GKE Node Service Account"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "node" {
  for_each = toset(local.node_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_service_account" "app" {
  account_id   = local.app_sa_id
  display_name = "Cielara App Secret Manager Identity"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_custom_role" "app_secret_manager" {
  role_id     = "cielaraAppSecretManager"
  title       = "Cielara App Secret Manager"
  description = "Least-privilege secret + version CRUD for the insights-backend app SA (Workload Identity). No setIamPolicy."
  permissions = local.app_secret_manager_permissions
  project     = var.project_id
  stage       = "GA"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "app_secret_manager" {
  project = var.project_id
  role    = google_project_iam_custom_role.app_secret_manager.id
  member  = "serviceAccount:${google_service_account.app.email}"
}

resource "google_project_iam_custom_role" "filestore_sweep" {
  role_id     = "cielaraProvisionerFilestoreSweep"
  title       = "Cielara Provisioner Filestore Sweep"
  description = "Least-privilege Filestore list/get/delete for the provisioner SA's post-destroy orphan sweep. No create/update."
  permissions = local.filestore_sweep_permissions
  project     = var.project_id
  stage       = "GA"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "deployer_filestore_sweep" {
  project = var.project_id
  role    = google_project_iam_custom_role.filestore_sweep.id
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# Customer-owned Cloud KMS asymmetric key the data plane signs its JWTs with;
# the private key never leaves this project and Cielara cannot read, rotate or
# destroy it. Only the dedicated signer SA (assumed by admin-backend, the sole
# token minter) gets sign + read-public-key, scoped to the key itself: the app,
# node and deployer SAs are granted nothing here. The keyring location must
# match the deploy form's region, which the control plane recomputes from.
resource "google_kms_key_ring" "jwt" {
  name     = "cielara-jwt"
  location = var.region
  project  = var.project_id

  depends_on = [time_sleep.api_propagation]
}

# KMS keys cannot be deleted, only their versions disabled/destroyed. Rotation
# and revocation stay customer-run:
#   rotate: gcloud kms keys versions create --keyring cielara-jwt --key jwt-signing --location <region>
#   revoke: gcloud kms keys versions disable <N> --keyring cielara-jwt --key jwt-signing --location <region>
resource "google_kms_crypto_key" "jwt_signing" {
  name     = "jwt-signing"
  key_ring = google_kms_key_ring.jwt.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm        = "EC_SIGN_P256_SHA256"
    protection_level = "SOFTWARE"
  }
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

resource "google_service_account" "jwt_signer" {
  account_id   = local.jwt_signer_sa_id
  display_name = "Cielara JWT Signer Identity"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

# Key-resource scope, not project scope: the signer role reaches exactly this
# one key.
resource "google_kms_crypto_key_iam_member" "jwt_signer" {
  crypto_key_id = google_kms_crypto_key.jwt_signing.id
  role          = google_project_iam_custom_role.app_jwt_signer.id
  member        = "serviceAccount:${google_service_account.jwt_signer.email}"
}

# Best-effort Workload Identity pre-binding (the pool only becomes usable once
# the cluster exists); the Cielara deployment terraform owns the binding for
# real. The [cielara/cielara-jwt-signer] KSA name is load-bearing.
resource "google_service_account_iam_member" "jwt_signer_wi" {
  service_account_id = google_service_account.jwt_signer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[cielara/cielara-jwt-signer]"
}

resource "google_service_account_iam_member" "deployer_token_creator" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_service_account_key" "deployer" {
  count = var.create_key ? 1 : 0

  service_account_id = google_service_account.deployer.name
}

# Upload this file in the Cielara deploy form. The key also lives in the
# Terraform state — protect the state like a credential (see backend.tf).
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
