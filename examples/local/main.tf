variable "port" {
  type    = number
  default = 2222
}

variable "admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

# CI sets opensearch_version to install an older release first, then
# upgrades to the circuit's own pin by applying again without it.
variable "opensearch_version" {
  type    = string
  default = null
}

module "opensearch" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  admin_password     = var.admin_password
  opensearch_version = var.opensearch_version
  cluster_name       = "local"
  heap_size          = "512m"
  settings           = { "action.auto_create_index" = "true" }
}
