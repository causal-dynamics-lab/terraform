variable "grafana_url" {
  description = "The Grafana Cloud stack's URL, https://<stack>.grafana.net."
  type        = string
}

variable "grafana_auth" {
  description = "A service account token of that stack with the Editor role (Administration → Service accounts)."
  type        = string
  sensitive   = true
}

variable "sm_url" {
  description = "The stack's Synthetic Monitoring API URL, as Testing & synthetics → Config shows it (it depends on the stack's region)."
  type        = string
}

variable "sm_access_token" {
  description = "A Synthetic Monitoring access token (Testing & synthetics → Config → Generate access token)."
  type        = string
  sensitive   = true
}

variable "pagerduty_integration_key" {
  description = "The Events API v2 integration key of the PagerDuty service that pages for TeamMind."
  type        = string
  sensitive   = true
}

variable "prometheus_data_source" {
  description = "The name of the stack's Prometheus data source, usually grafanacloud-<stack>-prom."
  type        = string
}

variable "loki_data_source" {
  description = "The name of the stack's Loki data source, usually grafanacloud-<stack>-logs."
  type        = string
}

variable "folder" {
  description = "The Grafana folder the rules live in; also names the contact point."
  type        = string
  default     = "TeamMind"
}

variable "servers" {
  description = "The servers to check from outside, keyed by their teammind_server label (the server root's `name`, or TEAMMIND_SERVER on a hand-built VM). url: the gate's /collections, which answers 401 without a token. self_signed: the gate's certificate is its own (tls_mode = self_signed)."
  type = map(object({
    url         = string
    self_signed = optional(bool, false)
  }))
  default = {}
  validation {
    condition     = alltrue([for s in values(var.servers) : can(regex("^https://[^/]+/collections$", s.url))])
    error_message = "Each url is https://<host>:<port>/collections."
  }
}

variable "probes" {
  description = "Synthetic Monitoring public probes that call each gate, by name. Their addresses must be inside the server's reader_cidrs."
  type        = list(string)
  default     = ["Mumbai", "Singapore", "Frankfurt"]
}

variable "check_job" {
  description = "The job label of the outside checks."
  type        = string
  default     = "teammind-gate"
}
