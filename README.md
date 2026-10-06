# Rocky Linux image mode on bare metal, with Artifact Keeper as the source of truth

Proof of concept behind the OpenTeams engineering blog post
*Rocky Linux Image Mode on Bare Metal, with Artifact Keeper as the Source of Truth*.

One [Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper) instance holds
everything an edge node boots from: Rocky Linux 10 and EPEL RPMs (proxy repos), RKE2
RPMs (proxy), our own `edge-site-config` RPM (hosted), a self-built Rocky 10 bootc base
image and the edge image layered on it (hosted OCI), and pull-through proxies for
quay.io and Docker Hub that the cluster's workloads use. A bare-metal node (here a QEMU
VM) boots the stock Rocky installer with a kickstart, pulls the edge image, and comes up
running RKE2. Day-2 is `bootc upgrade` against the same registry; rollback is built in.

```
dl.rockylinux.org ─┐                          ┌─> podman build (base, edge image)
rpm.rancher.io    ─┼─> Artifact Keeper :30080 ─┼─> Rocky installer + kickstart ─> edge node
registry-1.docker.io┘   rpm-* / oci-*          └─> bootc upgrade, RKE2 image pulls
```

## Layout

| Path | What |
|---|---|
| `registry/` | Artifact Keeper (compose, rootless podman), `up.sh`, idempotent `bootstrap.sh` that creates all repos, a CI token and `out/edge.repo` |
| `base/` | Builds the RESF SIG/Containers `rocky-bootc` recipe rootless, dnf pointed only at Artifact Keeper, pushes `oci-bootc/rocky-bootc-base:10` |
| `rpms/` | `edge-site-config` spec (RKE2 config, registries.yaml, MOTD, demo manifest, insecure-registry drop-in), built with rpmbuild in a Rocky container, uploaded to `rpm-edge-site` |
| `image/` | `Containerfile` for `oci-bootc/rocky-edge:10.2-<rel>`; build gate that fails on any non-Artifact-Keeper repo URL; `bootc container lint --fatal-warnings` |
| `deploy/` | Kickstart template, pxeboot media fetch, QEMU harness: `vm-install`, `vm-boot`, `vm-verify`, `vm-upgrade`, `vm-rollback`, `vm-ssh`, `vm-status` |
| `docs/` | `PLAN.md` (design), `findings-image.md` and `findings-deploy.md` (everything that broke, with exact errors and timings) |

Each directory has its own README with details and the deviations from upstream docs.

## Requirements

- Linux with rootless podman 5.x (`podman compose` or docker-compose), skopeo, qemu-system-x86_64,
  edk2-ovmf, curl, python3. No sudo is needed anywhere. `/dev/kvm` is used when present;
  otherwise QEMU falls back to software emulation (installs take ~10 min instead of ~2).
- An SSH key at `~/.ssh/id_ed25519.pub` (injected into the node via kickstart `sshkey`).
- About 8 GB RAM free for the VM and 6 GB of disk for images and media.

## Quick start

```bash
make registry-up     # start Artifact Keeper on http://localhost:30080, create repos + token
make base            # build the Rocky 10 bootc base rootless and push it (~4 min)
make rpm             # build edge-site-config 1.0-1 and 1.0-2, upload to rpm-edge-site
make image push      # build rocky-edge:10.2-1 and :10.2-2, push, point :10 at release 1
make vm-install      # kickstart install from oci-bootc/rocky-edge:10 into deploy/state/
make vm-boot         # boot it, wait for ssh, show bootc status / node Ready
make vm-verify       # nginx-demo Running and its digest cached in oci-dockerhub-proxy
make vm-upgrade      # promote :10.2-2 -> :10, bootc upgrade, reboot, verify
make vm-rollback     # bootc rollback, reboot, verify
make vm-ssh          # ssh -p 2222 root@localhost (key-only, root password locked)
```

Admin UI: http://localhost:30080 (user `admin`, password generated into `registry/.env`).
Generated secrets, the kickstart with your key, VM disks and media are all gitignored.

## What broke along the way

See `docs/findings-image.md` and `docs/findings-deploy.md`. Highlights:

- Rocky publishes no official bootc base image; the RESF recipe builds rootless as-is.
- The `bootc` kickstart command on Rocky 10.2 mislabels `/root/.ssh` and `/etc/resolv.conf`; use `ostreecontainer`.
- `/opt` is read-only in the base, so RKE2's CNI installer fails; link it to `var/opt`.
- The minimal base lacks `bubblewrap`, so `bootc upgrade` silently reverts at finalize time.
- Artifact Keeper's compose defaults refuse to start until you generate secrets; repos are private unless `is_public`; the OCI registry is path-based (`host:30080/<repo>/<image>`).

## License

MIT for everything in this repo. `base/upstream/rocky-bootc/` is vendored from
<https://git.resf.org/sig_containers/rocky-bootc> under its own license (see files there).
