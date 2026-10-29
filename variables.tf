variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "opensearch_version" {
  type        = string
  default     = "3.9.0"
  description = "OpenSearch 3.x release to install, such as \"3.9.0\". Raising it upgrades OpenSearch in place."

  validation {
    condition     = can(regex("^3\\.[0-9]+\\.[0-9]+$", var.opensearch_version))
    error_message = "opensearch_version must be a full 3.x release, such as \"3.9.0\"."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password for OpenSearch's admin user, set when OpenSearch first installs. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  # The security plugin's demo installer refuses a password without all
  # four kinds of character. Quotes, backslashes and spaces are left out so
  # the password passes through the shell and curl unchanged.
  validation {
    condition = (
      length(var.admin_password) >= 8 &&
      can(regex("[A-Z]", var.admin_password)) &&
      can(regex("[a-z]", var.admin_password)) &&
      can(regex("[0-9]", var.admin_password)) &&
      can(regex("[^A-Za-z0-9]", var.admin_password)) &&
      !can(regex("[\"\\\\'\\s]", var.admin_password))
    )
    error_message = "admin_password must be at least 8 characters with an uppercase letter, a lowercase letter, a digit and a special character, and no quotes, backslashes or spaces."
  }
}

variable "cluster_name" {
  type        = string
  default     = "opensearch"
  description = "cluster.name. Changing it on a node with data makes OpenSearch refuse to start, since the data belongs to the old cluster."

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.cluster_name))
    error_message = "cluster_name may use letters, digits, ., _ and -."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "IP address OpenSearch listens on, its network.host. \"0.0.0.0\" listens on every address."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0))
    error_message = "listen_address must be an IPv4 or IPv6 address, such as \"127.0.0.1\", \"10.0.0.5\" or \"0.0.0.0\"."
  }
}

variable "http_port" {
  type        = number
  default     = 9200
  description = "Port of the REST API, its http.port."

  validation {
    condition     = var.http_port >= 1 && var.http_port <= 65535 && floor(var.http_port) == var.http_port
    error_message = "http_port must be a port number from 1 to 65535."
  }
}

variable "heap_size" {
  type        = string
  default     = "1g"
  description = "JVM heap, set as both -Xms and -Xmx, such as \"512m\" or \"4g\". Half the host's memory is the usual choice, up to about 31g."

  validation {
    condition     = can(regex("^[1-9][0-9]*[mg]$", var.heap_size))
    error_message = "heap_size must be a whole number of megabytes or gigabytes, such as \"512m\" or \"4g\"."
  }
}

variable "settings" {
  type        = map(string)
  default     = {}
  description = "More opensearch.yml settings, such as { \"indices.query.bool.max_clause_count\" = \"4096\" }. Changing them restarts OpenSearch."

  validation {
    condition     = alltrue([for k, v in var.settings : can(regex("^[a-z0-9_]+(\\.[a-z0-9_]+)*$", k)) && !strcontains(v, "\n")])
    error_message = "Setting names are dotted lowercase words, such as \"indices.query.bool.max_clause_count\", and values can't contain line breaks."
  }

  # These are already in opensearch.yml, from the package, the demo
  # installer or the circuit's own inputs, and a key twice stops OpenSearch.
  validation {
    condition = alltrue([for k in keys(var.settings) : !(
      contains(["cluster.name", "node.name", "network.host", "http.port", "discovery.type", "node.max_local_storage_nodes", "transport.ssl.enforce_hostname_verification"], k) ||
      startswith(k, "path.") || startswith(k, "plugins.security.")
    )])
    error_message = "settings can't set cluster.name, node.name, network.host, http.port, discovery.type, path.*, plugins.security.*, node.max_local_storage_nodes or transport.ssl.enforce_hostname_verification. Use the circuit's own inputs for the first four."
  }
}

variable "tls_certificate" {
  type        = string
  default     = null
  description = "PEM certificate for OpenSearch's REST and transport layers, in place of the demo one. Set it with tls_private_key and tls_ca_certificate."

  validation {
    condition     = var.tls_certificate == null || startswith(trimspace(coalesce(var.tls_certificate, "-")), "-----BEGIN CERTIFICATE-----")
    error_message = "tls_certificate must be a PEM certificate."
  }

  validation {
    condition     = (var.tls_certificate == null) == (var.tls_ca_certificate == null)
    error_message = "Set tls_certificate and tls_ca_certificate together."
  }
}

variable "tls_ca_certificate" {
  type        = string
  default     = null
  description = "PEM certificate of the CA that signed tls_certificate."

  validation {
    condition     = var.tls_ca_certificate == null || startswith(trimspace(coalesce(var.tls_ca_certificate, "-")), "-----BEGIN CERTIFICATE-----")
    error_message = "tls_ca_certificate must be a PEM certificate."
  }
}

variable "tls_private_key" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "PKCS#8 PEM private key of tls_certificate. Pass it at run time; it never reaches state or the plan."

  validation {
    condition     = (var.tls_private_key == null) == (var.tls_certificate == null)
    error_message = "Set tls_private_key together with tls_certificate."
  }

  validation {
    condition     = var.tls_private_key == null || startswith(trimspace(coalesce(var.tls_private_key, "-")), "-----BEGIN PRIVATE KEY-----")
    error_message = "tls_private_key must be a PKCS#8 PEM key, starting -----BEGIN PRIVATE KEY-----. Convert others with openssl pkcs8 -topk8 -nocrypt."
  }
}
