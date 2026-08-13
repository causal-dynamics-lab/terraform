# Which app-SA / JWT signing resources already exist, so migrate mode imports
# what is there and creates what is not. The frozen scripts create none of them,
# so migrating a script-prepared project is the create path. Only read when
# migrate = true, so a fresh prepare needs no gcloud CLI.
data "external" "jwt_resources" {
  count = var.migrate ? 1 : 0

  program = [
    "bash",
    "${path.module}/check-jwt-resources.sh",
    var.project_id,
    var.region,
    local.app_sa_email,
  ]
}

locals {
  jwt_existing = {
    app_sa  = try(data.external.jwt_resources[0].result.app_sa, "false") == "true"
    keyring = try(data.external.jwt_resources[0].result.keyring, "false") == "true"
    key     = try(data.external.jwt_resources[0].result.key, "false") == "true"
    role    = try(data.external.jwt_resources[0].result.role, "false") == "true"
  }
}
