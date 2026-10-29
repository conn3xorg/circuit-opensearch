# Facts give each host's distribution, which picks OpenSearch's apt or yum
# repository and the command that installs the package.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  v    = var.opensearch_version
  repo = "https://artifacts.opensearch.org/releases/bundle/opensearch/3.x"

  password_file = "/etc/conn3x/opensearch/admin-password"
  config_file   = "/etc/opensearch/opensearch.yml"

  # The package's install script runs the security plugin's demo installer,
  # which fails unless OPENSEARCH_INITIAL_ADMIN_PASSWORD is set. A package
  # step can't pass it, so the install is a command that reads it from the
  # root-only file. The installer only sets the password the first time.
  install = {
    debian = "export OPENSEARCH_INITIAL_ADMIN_PASSWORD=\"$(cat ${local.password_file})\" DEBIAN_FRONTEND=noninteractive && apt-get install -y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold opensearch=${local.v}"
    redhat = "export OPENSEARCH_INITIAL_ADMIN_PASSWORD=\"$(cat ${local.password_file})\" && dnf -y -q install opensearch-${local.v}"
  }
  installed = {
    debian = "[ \"$(dpkg-query -W -f '$${db:Status-Status} $${Version}' opensearch 2>/dev/null)\" = 'installed ${local.v}' ]"
    redhat = "[ \"$(rpm -q --qf '%%{VERSION}' opensearch 2>/dev/null)\" = '${local.v}' ]"
  }

  # The demo installer has already appended the security plugin's settings
  # to opensearch.yml, so the circuit's settings go in a block of their own
  # after them rather than replacing the file. Values are JSON strings,
  # which YAML reads as they are.
  config = { for name, h in var.hosts : name => join("", [
    for k, val in merge(var.settings, {
      "cluster.name"   = var.cluster_name
      "node.name"      = name
      "network.host"   = var.listen_address
      "http.port"      = tostring(var.http_port)
      "discovery.type" = "single-node"
    }) : "${k}: ${jsonencode(val)}\n"
  ]) }

  # Where the circuit itself talks to OpenSearch. 0.0.0.0 and :: listen on
  # loopback too.
  check_host = contains(["0.0.0.0", "::"], var.listen_address) ? "127.0.0.1" : strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address
  url        = "https://${local.check_host}:${var.http_port}"

  # Own certificates go over the demo ones, under the same names, so the
  # paths the demo installer wrote into opensearch.yml stay right.
  tls = var.tls_certificate == null ? {} : { "esnode.pem" = var.tls_certificate, "root-ca.pem" = var.tls_ca_certificate }
}

circuit "opensearch" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # One repository serves every 3.x release, for Debian and Ubuntu in one
  # apt suite and for the whole Red Hat family in one yum repository. Its
  # signing subkey expires on 6 March 2027.
  step "repo" {
    repository {
      name       = "opensearch-3.x"
      url        = local.family[each.key] == "debian" ? "${local.repo}/apt" : "${local.repo}/yum"
      key        = file("${path.module}/files/opensearch-release.asc")
      suites     = local.family[each.key] == "debian" ? ["stable"] : null
      components = ["main"]
    }
  }

  # The checks below talk to OpenSearch's REST API with curl.
  step "curl" {
    package {
      name = "curl"
    }
  }

  step "password_dir" {
    directory {
      path = dirname(local.password_file)
      mode = "0700"
    }
  }

  # The password lands in a root-only file, never in state or the plan.
  step "admin_password" {
    file {
      path       = local.password_file
      content_wo = var.admin_password
    }
  }

  step "package" {
    command {
      command = local.install[local.family[each.key]]
      unless  = local.installed[local.family[each.key]]
    }
  }

  # The package raises it at boot through /usr/lib/sysctl.d, which can't
  # take effect until the next boot or doesn't take at all in a container.
  # This only raises it: Ubuntu 24.04 and Fedora already start with more.
  step "max_map_count" {
    command {
      command = "echo vm.max_map_count=262144 > /etc/sysctl.d/90-conn3x-opensearch.conf && sysctl -q -p /etc/sysctl.d/90-conn3x-opensearch.conf"
      unless  = "[ \"$(sysctl -n vm.max_map_count)\" -ge 262144 ]"
    }
  }

  step "config" {
    block {
      path    = local.config_file
      content = local.config[each.key]
    }
  }

  # Files in jvm.options.d come after jvm.options, so these win over its
  # -Xms1g and -Xmx1g.
  step "heap" {
    file {
      path    = "/etc/opensearch/jvm.options.d/conn3x.options"
      content = "-Xms${var.heap_size}\n-Xmx${var.heap_size}\n"
      owner   = "opensearch"
      group   = "opensearch"
      mode    = "0640"
    }
  }

  step "tls" {
    for_each = local.tls
    file {
      path    = "/etc/opensearch/${item.key}"
      content = item.value
      owner   = "opensearch"
      group   = "opensearch"
      mode    = "0640"
    }
  }

  step "tls_key" {
    for_each = var.tls_certificate == null ? [] : ["esnode-key.pem"]
    file {
      path       = "/etc/opensearch/${item.key}"
      content_wo = var.tls_private_key
      owner      = "opensearch"
      group      = "opensearch"
      mode       = "0640"
    }
  }

  # OpenSearch reads its settings, heap and certificates only at start. An
  # upgrade stops it, and on the Red Hat family leaves it stopped. It
  # runs here rather than in a handler so the steps below find it running
  # with them. On a first apply it's what starts it.
  step "restart" {
    command {
      command = "systemctl restart opensearch"
      triggers = {
        package = conn3x_command.opensearch__package[each.key].revision
        config  = conn3x_block.opensearch__config[each.key].revision
        heap    = conn3x_file.opensearch__heap[each.key].revision
        cert    = try(conn3x_file.opensearch__tls["${each.key}/esnode.pem"].revision, null)
        ca      = try(conn3x_file.opensearch__tls["${each.key}/root-ca.pem"].revision, null)
        key     = try(conn3x_file.opensearch__tls_key["${each.key}/esnode-key.pem"].revision, null)
      }
    }
  }

  step "running" {
    service {
      name    = "opensearch"
      state   = "started"
      enabled = true
    }
  }

  # The security plugin sets the admin password only on the first install,
  # so a later change to admin_password would otherwise go unnoticed. This
  # fails the apply until the password works. It also waits out the few
  # seconds the plugin takes to load its index after a start. The password
  # reaches curl on stdin, so it never shows in ps.
  step "admin" {
    command {
      command = "for _ in $(seq 90); do printf 'user = \"admin:%s\"\\n' \"$(cat ${local.password_file})\" | curl -sfk -K- -o /dev/null ${local.url}/_plugins/_security/authinfo && exit 0; sleep 2; done; echo 'OpenSearch did not accept admin_password as the admin password. OpenSearch sets it only on the first install, so change it in OpenSearch first, then here.' >&2; exit 1"
      unless  = "printf 'user = \"admin:%s\"\\n' \"$(cat ${local.password_file})\" | curl -sfk -K- -o /dev/null ${local.url}/_plugins/_security/authinfo"
      triggers = {
        password = conn3x_file.opensearch__admin_password[each.key].revision
        restart  = conn3x_command.opensearch__restart[each.key].revision
      }
    }
  }
}
