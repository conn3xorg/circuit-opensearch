# circuit-opensearch

A Conn3x circuit that installs OpenSearch 3.x from OpenSearch's own apt and yum repositories and runs it as a single node, with the security plugin on, an admin password you choose, and HTTPS on the REST API. It's the self-hosted counterpart to a managed domain such as [terraform-aws-modules/opensearch](https://github.com/terraform-aws-modules/terraform-aws-opensearch): the same search engine, on a machine you run.

Getting OpenSearch up by hand takes more steps than it looks. The package won't finish installing unless `OPENSEARCH_INITIAL_ADMIN_PASSWORD` is in its environment, the kernel needs `vm.max_map_count` raised, the heap lives in a JVM options file, and a single node has to be told it's alone. The circuit does all of that the same way on Debian, Ubuntu, Fedora and Rocky Linux, pins the release, and keeps the password out of state.

## Usage

```hcl
variable "opensearch_admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "opensearch" {
  source = "github.com/conn3xorg/circuit-opensearch?ref=v0.1.0"

  hosts                = { search = "192.168.1.40" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  admin_password = var.opensearch_admin_password
  cluster_name   = "search"
  heap_size      = "4g"
}
```

Then run `conn3x init` and `conn3x apply` with the password in the environment:

```sh
export TF_VAR_opensearch_admin_password='...'
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the password too, since Conn3x checks the file on the host against it. Then, on the host:

```sh
curl -k -u "admin:$PASSWORD" https://127.0.0.1:9200/_cluster/health
```

OpenSearch listens on `127.0.0.1` unless you set `listen_address`. To reach it from other machines, set `listen_address = "0.0.0.0"` or the host's private address, and put a firewall in front of port 9200, such as [circuit-firewall](https://github.com/conn3xorg/circuit-firewall).

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its repository by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.search : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Heap size

OpenSearch's own advice is half the host's memory for the heap, and no more than about 31 GB, leaving the rest to the operating system's file cache. The circuit can't see a host's memory when it plans, so `heap_size` is a fixed `1g` unless you set it. On a 4 GB machine, `"2g"`; on 16 GB, `"8g"`.

### The admin password

`admin_password` reaches the host through a root-only file, `/etc/conn3x/opensearch/admin-password`, never through state or the plan. The package's install script hands it to the security plugin, which hashes it as the `admin` user's password. The plugin wants at least 8 characters with an uppercase letter, a lowercase letter, a digit and a special character; the circuit checks that before it connects, and also turns away quotes, backslashes and spaces.

OpenSearch only takes the password on the first install. After that, each apply checks that `admin_password` still logs in, and fails if it doesn't, rather than leaving the variable and OpenSearch quietly disagreeing. `admin` is a reserved user, so it can't change its own password through the account API. With the demo certificates, the demo admin certificate can:

```sh
cd /etc/opensearch
curl --cacert root-ca.pem --cert kirk.pem --key kirk-key.pem \
  -X PATCH https://127.0.0.1:9200/_plugins/_security/api/internalusers/admin \
  -H 'Content-Type: application/json' \
  -d '[{"op": "add", "path": "/password", "value": "NEW-password-1"}]'
```

Then set `admin_password` to the new one and apply.

### Certificates

The package's install script sets up the security plugin with OpenSearch's demo certificates: a node certificate, `esnode.pem`, a CA, `root-ca.pem`, and an admin certificate, `kirk.pem`. They're the same files in every OpenSearch download, private keys included, and they're for testing only: anyone can present `kirk.pem`, which OpenSearch treats as a superuser. Use them on a laptop or behind a firewall you trust, never on a node other machines can reach.

To use your own, set `tls_certificate`, `tls_private_key` and `tls_ca_certificate`. The circuit writes them over `esnode.pem`, `esnode-key.pem` and `root-ca.pem`, which `opensearch.yml` already points at for both the REST API and the transport layer, then restarts OpenSearch. The key is write-only, like the password: pass it from an ephemeral variable.

```hcl
variable "opensearch_tls_key" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "opensearch" {
  # ...
  tls_certificate    = file("${path.module}/certs/search.pem")
  tls_ca_certificate = file("${path.module}/certs/ca.pem")
  tls_private_key    = var.opensearch_tls_key
}
```

The key must be PKCS#8, starting `-----BEGIN PRIVATE KEY-----`; `openssl pkcs8 -topk8 -nocrypt -in key.pem` converts an older one. Give the certificate a subject alternative name for each name and address clients use, and both `serverAuth` and `clientAuth` extended key usage, since the transport layer uses it in both directions.

Your CA replaces the demo one, so `kirk.pem` stops being trusted, and the password change above no longer works as written. The demo installer's other settings, such as `plugins.security.allow_unsafe_democertificates: true`, stay in `opensearch.yml`; with your own certificates in place they have nothing to allow.

## What it does

On each host, in order:

1. Adds OpenSearch's 3.x repository with its signing key: an apt source on Debian and Ubuntu, a yum repository on the Red Hat family. Then installs `curl`, which the checks below use.
2. Writes `admin_password` to `/etc/conn3x/opensearch/admin-password`, mode `0600`.
3. Installs `opensearch` at `opensearch_version`, with `OPENSEARCH_INITIAL_ADMIN_PASSWORD` read from that file. The package's script sets up the security plugin with the demo certificates and the password. A higher version upgrades it in place.
4. Raises `vm.max_map_count` to 262144 if it's lower, and keeps it there in `/etc/sysctl.d/90-conn3x-opensearch.conf`. The package also ships `/usr/lib/sysctl.d/opensearch.conf`, which sets it to 262144 at boot. That's lower than Ubuntu 24.04's default of 1048576, and on an Ubuntu droplet it won after a reboot.
5. Adds a managed block to the end of `/etc/opensearch/opensearch.yml` with `cluster.name`, `node.name` (the host's key in `hosts`), `network.host`, `http.port`, `discovery.type: single-node` and your `settings`. It leaves the rest of the file, including the security plugin's settings, alone.
6. Writes the heap to `/etc/opensearch/jvm.options.d/conn3x.options`, which wins over `-Xms1g` and `-Xmx1g` in `jvm.options`.
7. Writes your certificates and key, if you gave them.
8. Restarts OpenSearch when any of that changed, or after an install or upgrade, and starts it at boot. An upgrade stops OpenSearch, and on the Red Hat family leaves it stopped.
9. Logs in as `admin` with the password and waits, up to three minutes, for the security plugin to answer. The password reaches `curl` on stdin, so it doesn't show in `ps`.

### What it doesn't do

- It runs one node per host, each its own cluster. Several hosts in `hosts` make several single-node clusters, not one cluster. Joining nodes together, with seed hosts and initial cluster manager nodes, is left out until it's been tested on real machines.
- It doesn't install OpenSearch Dashboards.
- It doesn't open a firewall port or touch firewalld or ufw.
- It doesn't install OpenSearch 2.x, which has its own repository and signing key, and it doesn't downgrade.
- It doesn't create users, roles or indices. Use the REST API, or the [OpenSearch provider](https://registry.terraform.io/providers/opensearch-project/opensearch/latest) against the running node.
- Deleting the module leaves OpenSearch installed and running with the last settings.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. The name becomes the node's `node.name`. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `admin_password` | string | Required | Password for OpenSearch's `admin` user, set on the first install. Ephemeral and sensitive: pass it with `-var` or `TF_VAR_`. At least 8 characters with an uppercase letter, a lowercase letter, a digit and a special character, and no quotes, backslashes or spaces. |
| `opensearch_version` | string | `"3.9.0"` | OpenSearch 3.x release to install. Raising it upgrades in place. |
| `cluster_name` | string | `"opensearch"` | `cluster.name`. Changing it on a node with data stops OpenSearch from starting, since the data belongs to the old cluster. |
| `listen_address` | string | `"127.0.0.1"` | IP address OpenSearch listens on, its `network.host`. `"0.0.0.0"` listens on every address. |
| `http_port` | number | `9200` | Port of the REST API, its `http.port`. |
| `heap_size` | string | `"1g"` | JVM heap, as both `-Xms` and `-Xmx`, such as `"512m"` or `"4g"`. |
| `settings` | map(string) | `{}` | More `opensearch.yml` settings, such as `{ "indices.query.bool.max_clause_count" = "4096" }`. Changing them restarts OpenSearch. Settings already in the file, from the package, the demo installer or the inputs above, aren't allowed, since a key twice stops OpenSearch. |
| `tls_certificate` | string | `null` | PEM certificate for the REST API and transport layer, in place of the demo one. Set it with `tls_private_key` and `tls_ca_certificate`. |
| `tls_private_key` | string | `null` | PKCS#8 PEM key of `tls_certificate`. Ephemeral and sensitive. |
| `tls_ca_certificate` | string | `null` | PEM certificate of the CA that signed `tls_certificate`. |

## Outputs

| Name | Description |
| --- | --- |
| `config_file` | Path of the file the circuit adds its settings to, `/etc/opensearch/opensearch.yml`. |
| `url` | URL the circuit checks the REST API on, from each host itself, such as `https://127.0.0.1:9200`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host, with outbound HTTPS to artifacts.opensearch.org. The droplets it was tested on had 4 GB of memory. The package takes about 1.1 GB of disk. amd64 and arm64.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13, with OpenSearch 3.9.0. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, that cluster health is green or yellow, and indexes a document and finds it with a search. The same ran by hand on arm64, along with an upgrade from 3.8.0 to 3.9.0 on Ubuntu 24.04 and Rocky Linux 10, which kept the indexed document, a heap change, a wrong `admin_password`, which failed the apply with the message above, a password changed with the admin certificate and then in `admin_password`, and your own certificates on Fedora 45, checked with `curl --cacert` against the new CA.

On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, both `s-2vcpu-4gb`, the circuit applied with `listen_address = "0.0.0.0"` and a 2 GB heap. Cluster health was green, and a document indexed from another machine was found by a search. Both came back after a reboot with OpenSearch running, the document still there and the second plan clean. On Rocky Linux OpenSearch runs as `unconfined_service_t`, and the audit log had no denials.

## License

MPL-2.0. See [LICENSE](LICENSE). OpenSearch itself is Apache-2.0.
