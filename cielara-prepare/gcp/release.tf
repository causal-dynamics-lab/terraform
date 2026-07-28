# Stamped by the release workflow when a release is cut from the release
# branch; 0.0.0-dev on unreleased checkouts.
locals {
  prepare_version = "0.0.0-dev"
  prepare_module  = "cielara-prepare/gcp"

  release_channel = (
    length(regexall("-alpha\\.", local.prepare_version)) > 0 ? "alpha" :
    length(regexall("-beta\\.", local.prepare_version)) > 0 ? "beta" :
    local.prepare_version == "0.0.0-dev" ? "dev" : "stable"
  )
}
