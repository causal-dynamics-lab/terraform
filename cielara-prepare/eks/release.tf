# Stamped by the release workflow on the detached commit each release tag
# points to; 0.0.0-dev on every branch checkout.
locals {
  prepare_version = "0.4.0-alpha.9"
  # Source commit on the release branch, stamped at alpha time and inherited
  # unchanged by beta/stable promotions: equal revisions mean identical trees.
  prepare_revision = "a4b52a08c34dd5bdbb1875340a4d05595aa33fb4"
  prepare_module   = "cielara-prepare/eks"

  release_channel = (
    length(regexall("-alpha\\.", local.prepare_version)) > 0 ? "alpha" :
    length(regexall("-beta\\.", local.prepare_version)) > 0 ? "beta" :
    local.prepare_version == "0.0.0-dev" ? "dev" : "stable"
  )
}
