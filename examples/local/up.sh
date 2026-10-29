#!/usr/bin/env sh
# Starts a throwaway host on 127.0.0.1:$PORT (default 2222) that Conn3x can
# configure, with a fresh SSH key and its host key in ./known_hosts.
# CONTAINERFILE picks another image, such as one of Conn3x's test images.
# Needs Podman, since the host runs systemd. The container is privileged,
# since OpenSearch's systemd unit sandboxes itself in ways an unprivileged
# container can't set up. Rootful Podman is simplest:
# CONTAINER_CONNECTION=podman-machine-default-root on a Mac, or
# PODMAN="sudo podman" on Linux.
set -eu
cd "$(dirname "$0")"
port=${PORT:-2222}
containerfile=${CONTAINERFILE:-Containerfile}
name=${NAME:-circuit-opensearch}

podman=${PODMAN:-podman}
[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C "$name" -f id_ed25519
$podman build -q -f "$containerfile" -t "$name" "$(dirname "$containerfile")" >/dev/null
$podman rm -f -v "$name" >/dev/null 2>&1 || true
$podman run -d --name "$name" --systemd=always --privileged \
  -p "127.0.0.1:$port:22" "$name" >/dev/null
$podman exec -i "$name" sh -c 'cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' < id_ed25519.pub
$podman exec "$name" timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true

# Two things only a container needs. OpenSearch's unit makes /proc/self/cgroup
# and a few other paths read-only, which systemd can't do inside one. And
# the package loads its own vm.max_map_count through systemd-sysctl, which
# in a privileged container would change it for every container on the
# machine.
$podman exec "$name" sh -c 'mkdir -p /etc/systemd/system/opensearch.service.d && printf "[Service]\nReadOnlyPaths=\n" > /etc/systemd/system/opensearch.service.d/container.conf && systemctl mask -q systemd-sysctl.service 2>/dev/null'

# vm.max_map_count belongs to the kernel the container shares, which the
# container can't change. OpenSearch wants 262144 or more.
count=$($podman exec "$name" cat /proc/sys/vm/max_map_count)
if [ "$count" -lt 262144 ]; then
  echo "vm.max_map_count is $count on the machine running the container, and OpenSearch needs 262144." >&2
  echo "Raise it there with: sudo sysctl -w vm.max_map_count=262144" >&2
  echo "(on a Mac: podman machine ssh sudo sysctl -w vm.max_map_count=262144)" >&2
  exit 1
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ssh-keyscan -p "$port" 127.0.0.1 > known_hosts 2>/dev/null && [ -s known_hosts ]; then
    echo "Ready on 127.0.0.1:$port. Now run: conn3x init && conn3x apply -var port=$port"
    exit 0
  fi
  sleep 1
done
echo "The container started, but SSH didn't answer on 127.0.0.1:$port." >&2
exit 1
