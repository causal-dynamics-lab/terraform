# Prepares a customer GCP project for a Cielara GKE deployment: the service
# accounts, IAM roles, and APIs the Cielara control plane's Terraform assumes
# exist when it later provisions the cluster.
#
# Every name below is load-bearing: the Cielara deploy references these service
# accounts and roles by deterministic name and does not create them. Renaming
# anything here breaks the deploy. The resource set mirrors prepare-gke.sh
# byte-for-byte (a parity test in the Cielara control plane keeps them in
# lockstep for as long as both ship).

locals {
  deployer_sa_id = "cielara"
  node_sa_id     = "gke-node-sa"
  app_sa_id      = "cielara-app"

  deployer_sa_email = "${local.deployer_sa_id}@${var.project_id}.iam.gserviceaccount.com"
  node_sa_email     = "${local.node_sa_id}@${var.project_id}.iam.gserviceaccount.com"
  app_sa_email      = "${local.app_sa_id}@${var.project_id}.iam.gserviceaccount.com"

  # The deploy's Terraform authenticates as the deployer SA, which is granted
  # no roles/serviceusage.* and so cannot enable an API itself. Every
  # google_project_service the deploy declares must be pre-enabled here.
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
  ]

  # Minimal role set for the deployer SA. secretmanager.admin is project-wide
  # because the deploy creates dynamically named secrets at the project parent
  # (no per-resource condition can gate secrets.create).
  # iam.serviceAccountAdmin is required because the deploy creates the External
  # Secrets Operator service account.
  deployer_roles = [
    "roles/container.admin",
    "roles/compute.networkAdmin",
    "roles/compute.loadBalancerAdmin",
    "roles/cloudsql.admin",
    "roles/servicenetworking.networksAdmin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
  ]

  # Google's documented baseline for a custom GKE node service account:
  # control-plane registration, logs, metrics, resource metadata, image pulls.
  node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]

  # Exactly the Secret Manager calls the Cielara app makes (secret + version
  # CRUD), minus setIamPolicy — deliberately not roles/secretmanager.admin.
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

  # Post-destroy orphan sweep only: the deployer SA reclaims Filestore
  # instances the in-cluster CSI drain missed. list/get/delete, never
  # create/update.
  filestore_sweep_permissions = [
    "file.instances.list",
    "file.instances.get",
    "file.instances.delete",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  project = var.project_id
  service = each.value

  # Cielara resources may be adopted or destroyed independently of the rest of
  # the project; never switch a shared API off underneath other workloads.
  disable_on_destroy = false
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

# The node pool runs as this SA instead of the project's default Compute
# Engine SA, which many orgs disable; the deploy references it by
# deterministic email and does not create it.
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

# The Cielara app pod assumes this SA via Workload Identity to store its
# runtime credentials in Secret Manager. The Workload Identity binding itself
# is NOT declared here: the project's WI pool only exists once the cluster is
# created, which happens after prepare — the deploy's Terraform owns that
# binding.
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

# SignBlob on itself: the control plane generates GCS signed URLs as this SA
# when uploading the terraform code mirror.
resource "google_service_account_iam_member" "deployer_token_creator" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_service_account_key" "deployer" {
  count = var.create_key ? 1 : 0

  service_account_id = google_service_account.deployer.name
}

# The handback: upload this file in the Cielara deploy form. The key also
# lives in the Terraform state — protect the state like a credential (see
# README / backend.tf).
resource "local_sensitive_file" "key" {
  count = var.create_key ? 1 : 0

  filename        = var.key_output_path
  content         = base64decode(google_service_account_key.deployer[0].private_key)
  file_permission = "0600"
}
