# Prepares a customer GCP project for a Cielara VM deployment: the service
# account, IAM roles, and APIs the Cielara control plane's Terraform assumes
# exist when it later provisions the VM.
#
# Every name below is load-bearing: the Cielara deploy references the service
# account by deterministic name and does not create it. The resource set
# mirrors prepare-gcp.sh byte-for-byte (a parity test in the Cielara control
# plane keeps them in lockstep for as long as both ship).

locals {
  deployer_sa_id    = "cielara"
  deployer_sa_email = "${local.deployer_sa_id}@${var.project_id}.iam.gserviceaccount.com"

  # The deploy's Terraform authenticates as the deployer SA, which is granted
  # no roles/serviceusage.* and so cannot enable an API itself. Every
  # google_project_service the deploy declares must be pre-enabled here.
  apis = [
    "secretmanager.googleapis.com",
    "compute.googleapis.com",
    "logging.googleapis.com",
    "iap.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]

  # Minimal role set for VM provisioning: instance + network + LB management,
  # IAP tunnel access for the operator path, Cloud SQL for the data layer.
  # Broader than the GKE flavor by design (GCE VMs need instanceAdmin,
  # securityAdmin, storageAdmin, IAP). Secret Manager access is granted via
  # the custom role below, not a predefined role.
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

  # Least-privilege Secret Manager custom role instead of
  # roles/secretmanager.admin (pentest B4). The VM path uses one SA for both
  # provisioning and runtime and never binds per-secret IAM, so it does not
  # need admin's secrets.setIamPolicy - excluded deliberately so a leaked key
  # cannot re-grant access to arbitrary project secrets. Project scope is
  # unavoidable: secrets.create targets the project parent.
  # versions.enable/disable: google_secret_manager_secret_version reconciles
  # the version's enabled state on every apply - without them PrepareDatabase
  # 403s on 'secretmanager.versions.enable'.
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

  # Cielara resources may be adopted or destroyed independently of the rest of
  # the project; never switch a shared API off underneath other workloads.
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
  description = "Least-privilege secret + version CRUD for the GCP VM SA. No setIamPolicy (pentest B4)."
  permissions = local.vm_secret_manager_permissions
  stage       = "GA"
}

resource "google_project_iam_member" "deployer_vm_secret_manager" {
  project = var.project_id
  role    = google_project_iam_custom_role.vm_secret_manager.id
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# actAs itself: required to attach the SA to the VMs it creates.
resource "google_service_account_iam_member" "deployer_self_user" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

# SignBlob on itself: required for GCS signed URL generation.
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
