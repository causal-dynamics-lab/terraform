# Stamped by the release workflow on the detached commit each release tag
# points to; 0.0.0-dev on every branch checkout.
locals {
  prepare_version = "0.4.0-alpha.4"
  # Source commit on the release branch, stamped at alpha time and inherited
  # unchanged by beta/stable promotions: equal revisions mean identical trees.
  prepare_revision = "3923556ed5e13a0df8c37a82f48cb04658d73a7c"
  prepare_module   = "cielara-prepare/gke"

  release_channel = (
    length(regexall("-alpha\\.", local.prepare_version)) > 0 ? "alpha" :
    length(regexall("-beta\\.", local.prepare_version)) > 0 ? "beta" :
    local.prepare_version == "0.0.0-dev" ? "dev" : "stable"
  )
}
