# Stamped by the release workflow on the detached commit each release tag
# points to; 0.0.0-dev on every branch checkout.
locals {
  prepare_version = "0.4.0-alpha.15"
  # Source commit on the release branch, stamped at alpha time and inherited
  # unchanged by beta/stable promotions: equal revisions mean identical trees.
  prepare_revision = "0a890a7e49b55ad2cf4b0495442e7bd02086f164"
  prepare_module   = "cielara-prepare/gcp"

  release_channel = (
    length(regexall("-alpha\\.", local.prepare_version)) > 0 ? "alpha" :
    length(regexall("-beta\\.", local.prepare_version)) > 0 ? "beta" :
    local.prepare_version == "0.0.0-dev" ? "dev" : "stable"
  )
}
