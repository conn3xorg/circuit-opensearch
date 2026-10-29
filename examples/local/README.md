# Local example

Applies circuit-opensearch to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman, and about 2 GB of memory free for the container.

OpenSearch's systemd unit sandboxes itself, which only works in a privileged container, so this is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
export TF_VAR_admin_password='Choose-a-Passw0rd!'
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To look at the result:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  "curl -sk -u 'admin:$TF_VAR_admin_password' https://127.0.0.1:9200/_cluster/health"
```

A container shares the kernel of the machine it runs on, so `vm.max_map_count` is that machine's, and the container can't raise it. `up.sh` stops with the command to run if it's below the 262144 OpenSearch wants. It also adds two things only a container needs: a drop-in that lifts the unit's read-only paths, and a mask on `systemd-sysctl`, so the package's own `vm.max_map_count` doesn't change the value for every container on the machine.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
