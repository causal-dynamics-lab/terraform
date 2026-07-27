# Every name below is load-bearing: the Cielara deploy references the service
# account and role by deterministic name and does not create them.

locals {
  deployer_sa_id    = "cielara"
  deployer_sa_email = "${local.deployer_sa_id}@${var.project_id}.iam.gserviceaccount.com"

  apis = [
    "secretmanager.googleapis.com",
    "compute.googleapis.com",
    "logging.googleapis.com",
    "iap.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "cloudresourcemanager.googleapis.com",
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
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  project = var.project_id
  service = each.value

  # Never switch a shared API off underneath your other workloads.
  disable_on_destroy = false
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
