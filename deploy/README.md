# deploy/ — kickstart a QEMU "bare-metal" node from Artifact Keeper

This directory turns the bootc edge image in Artifact Keeper
(`oci-bootc/rocky-edge:10`) into a running node, then drives day-2
upgrade and rollback. The node is a QEMU VM with UEFI (OVMF), a virtio disk
and user-mode networking, so it sees the host (and Artifact Keeper) as
`10.0.2.2`. Nothing here needs root.

## Flow

```
make vm-install    # Anaconda netboot + kickstart -> ostreecontainer pull from AK -> disk
make vm-boot       # boot disk in background, wait for ssh, wait for node Ready, show status
make vm-verify     # nginx-demo Running, image pulled via AK's oci-dockerhub-proxy
make vm-upgrade    # retag rocky-edge:10.2-2 -> :10 in AK, bootc upgrade, reboot, verify
make vm-rollback   # bootc rollback, reboot, verify
make vm-ssh        # ssh -p 2222 root@localhost
make vm-status     # one-screen summary
make vm-stop       # clean poweroff
make vm-clean      # stop + delete deploy/state (CLEAN_CACHE=1 also drops the media cache)
```

All targets are thin wrappers over the scripts of the same name. Every
setting in `lib.sh` can be overridden as an environment or make variable:

| Variable | Default | Meaning |
|---|---|---|
| `IMAGE` | `rocky-edge:10` | image (under `IMAGE_REPO`) the node installs and tracks |
| `IMAGE_REPO` | `oci-bootc` | Artifact Keeper repo key |
| `REGISTRY` | `10.0.2.2:30080` | registry as seen from the VM |
| `HOST_REGISTRY` | `localhost:30080` | registry as seen from this host (skopeo) |
| `PROMOTE_FROM` | `rocky-edge:10.2-2` | `vm-upgrade` retags this to `IMAGE` first; empty = skip |
| `VM_SMP` / `VM_MEM` | `6` / `8192` | vCPUs / MiB |
| `VM_DISK_SIZE` | `40G` | qcow2 virtual size |
| `SSH_PORT` / `KS_PORT` | `2222` / `8000` | host ports (ssh forward, kickstart http) |
| `SSH_KEY` | `~/.ssh/id_ed25519` | private key; `SSH_PUBKEY` defaults to `$SSH_KEY.pub` |
| `NODE_HOSTNAME` | `edge-node-01` | kickstart hostname |
| `INSTALL_TIMEOUT` | `2400` | seconds before `vm-install` gives up |
| `WAIT_READY` | `1200` | seconds `vm-boot` waits for the k8s node to be Ready (0 = skip) |

## Files

| File | What |
|---|---|
| `ks.cfg.in` | kickstart template (`@REGISTRY@`, `@IMAGE@`, `@SSH_KEY@`, `@HOSTNAME@`) |
| `render-ks.sh` | renders it to `state/www/ks.cfg`, reading the public key at render time |
| `serve-ks.sh` | `python3 -m http.server` on `0.0.0.0:8000` serving only `state/www/` (pid file) |
| `fetch-media.sh` | caches Rocky 10.2 pxeboot `vmlinuz`/`initrd.img` in `cache/`, sha256-checked against `.treeinfo` |
| `vm-install.sh` | fresh qcow2 + OVMF vars, headless install, follows Anaconda milestones in the serial log |
| `vm-boot.sh` | daemonized QEMU with `hostfwd tcp::2222-:22`, status report |
| `vm-verify.sh` | workload + pull-through checks (guest and Artifact Keeper API) |
| `vm-upgrade.sh`, `vm-rollback.sh` | day-2, with digest assertions |
| `vm-ssh.sh`, `vm-status.sh`, `vm-stop.sh`, `vm-clean.sh` | the rest |
| `lib.sh`, `k8s-detect.sh` | shared settings/helpers; RKE2 vs k3s detection |
| `deploy.mk` | make targets, included by the root `Makefile` |

`state/` (disk, OVMF vars, serial logs, `timings.log`, pid files, rendered
kickstart) and `cache/` (install media) are gitignored.

## Why it looks like this

- **No ISO.** The installer is the mirror's pxeboot kernel/initrd with
  `inst.stage2=https://dl.rockylinux.org/pub/rocky/10.2/BaseOS/x86_64/os/`,
  which is also how a PXE/iPXE bare-metal deployment would boot it.
- **`ostreecontainer`, not `bootc`.** The kickstart `bootc` command on Rocky
  10.2 leaves `/root/.ssh` and `/etc/resolv.conf` mislabelled (SELinux AVCs for
  sshd and NetworkManager on first boot). `ostreecontainer` labels correctly.
- **Insecure registry.** Artifact Keeper is plain HTTP in this PoC. `%pre`
  writes a `registries.conf.d` drop-in so Anaconda can pull; `%post` writes the
  same into the installed `/etc` so `bootc upgrade` works even if an image
  forgets to bake it.
- **TCG.** Without `/dev/kvm` everything runs under TCG (`-cpu max`,
  `thread=multi`): Anaconda takes ~5 min to start, the install ~10 min total,
  ssh ~1 min after power-on, RKE2 Ready ~4.5 min later, reboots ~2.5 min. With a usable `/dev/kvm` the scripts switch to `-accel kvm
  -cpu host` automatically.
- **SSH waits are gentle.** Under slirp every host connection arrives from
  `10.0.2.2`; OpenSSH's `PerSourcePenalties` can block that source after
  repeated failed or aborted attempts. The wait loop uses `BatchMode=yes`,
  the right key only, and sleeps 10-15 s between tries.
- **Root is key-only.** `rootpw --lock` + kickstart `sshkey` with the
  operator's own public key; nothing secret is in git.
