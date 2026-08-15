# Stamped by the release workflow on the detached commit each release tag
# points to; 0.0.0-dev on every branch checkout.
locals {
  prepare_version = "0.4.0-beta.7"
  # Source commit on the release branch, stamped at alpha time and inherited
  # unchanged by beta/stable promotions: equal revisions mean identical trees.
  prepare_revision = "9ae540e63bb4bbf39b871f803ea87de553a80fb5"
  prepare_module   = "cielara-prepare/eks"

  release_channel = (
    length(regexall("-alpha\\.", local.prepare_version)) > 0 ? "alpha" :
    length(regexall("-beta\\.", local.prepare_version)) > 0 ? "beta" :
    local.prepare_version == "0.0.0-dev" ? "dev" : "stable"
  )
}
