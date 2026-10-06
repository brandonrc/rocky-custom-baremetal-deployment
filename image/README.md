# image/ — the edge OS image

`localhost:30080/oci-bootc/rocky-edge` = the AK-hosted base
(`oci-bootc/rocky-bootc-base:10`) + NetworkManager, openssh-server,
kernel-modules-extra (matched to the base kernel), rke2-server 1.36,
rke2-selinux and `edge-site-config-1.0-<rel>`, with a serial console karg and
`bubblewrap` (needed by ostree to finalize SELinux policy on upgrade; findings section 7),
a persistent journal, and `/opt -> var/opt` (the RESF base ships a read-only `/opt`; RKE2's CNI installer
writes `/opt/cni/bin`, see docs/findings-image.md section 5).

| Tag | Content |
|---|---|
| `rocky-edge:10.2-1` | edge-site-config 1.0-1 |
| `rocky-edge:10.2-2` | edge-site-config 1.0-2 (day-2 demo) |
| `rocky-edge:10` | floating; points at `10.2-1` after `make push`, move it with `make promote REL=2` |

From the VM the image is `10.0.2.2:30080/oci-bootc/rocky-edge:10` (anonymous pull).

## Only-Artifact-Keeper property

- `FROM` is the Artifact Keeper copy of the base, never an external registry.
- The base's stock `/etc/yum.repos.d/*.repo` are deleted; dnf runs with
  `--setopt=reposdir=/tmp/build-repos` (repos at `host.containers.internal:30080`).
- The image ships `/etc/yum.repos.d/edge.repo` with the same repos at `10.0.2.2:30080`
  (the edge node's view of the registry).
- A `RUN` step fails the build if any `baseurl`/`mirrorlist`/`metalink` in
  `/etc/yum.repos.d` does not contain `:30080/`; `build.sh` checks again from outside.

## Files

| Path | What |
|---|---|
| `Containerfile` | two install layers: OS+RKE2 (cached across site releases), then edge-site-config only |
| `rootfs/usr/lib/bootc/kargs.d/10-console.toml` | `console=tty0 console=ttyS0,115200n8` |
| `rootfs/usr/lib/tmpfiles.d/50-edge-image.conf` | tmpfiles entries for package-owned `/var` dirs (keeps lint warning-free) and `/var/opt/cni/bin` |
| `setup-host.sh` | user-level `~/.config/containers/registries.conf.d/50-artifact-keeper-local.conf` marking `localhost:30080` insecure (no sudo) |
| `build.sh` | renders repo files, builds `localhost/rocky-edge:<osver>-<rel>`, repo check, smoke test, `bootc container lint --fatal-warnings` |
| `push.sh` | pushes `<osver>-<rel>` tags, `skopeo copy` for the floating `:10` |

## Usage

```bash
make image            # builds releases 1 and 2 (SITE_RELEASE=N image/build.sh)
make push             # pushes 10.2-1, 10.2-2; :10 -> 10.2-1
make promote REL=2    # :10 -> 10.2-2 (what deploy/vm-upgrade.sh also does)
```

Note: `make push` always re-points `:10` at `REL` (default 1), so running it
after a day-2 promote rolls the floating tag back.
