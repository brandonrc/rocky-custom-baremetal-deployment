> **This repository has moved.** The code and documentation now live in the Artifact Keeper walkthroughs repository:
> [github.com/artifact-keeper/walkthroughs](https://github.com/artifact-keeper/walkthroughs/tree/main/rocky-linux-image-mode-bare-metal), with the narrated guide at
> [artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal](https://artifact-keeper.github.io/walkthroughs/rocky-linux-image-mode-bare-metal/).
> This repository is archived and kept for history and for the issues that reference it.

# Rocky Linux image mode on bare metal, with Artifact Keeper as the source of truth

Proof of concept behind the OpenTeams engineering blog post
[Rocky Linux Image Mode on Bare Metal, with Artifact Keeper as the Source of Truth](https://openteams.com/rocky-linux-image-mode-artifact-keeper/).

**Documentation:** <https://brandonrc.github.io/rocky-custom-baremetal-deployment/>
(setup, walkthrough, architecture, Artifact Keeper notes, timings and the findings).

One [Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper) instance holds
everything an edge node boots from: Rocky Linux 10 and EPEL RPMs (proxy repos), RKE2
RPMs (proxy), our own `edge-site-config` RPM (hosted), a self-built Rocky 10 bootc base
image and the edge image layered on it (hosted OCI), pull-through proxies for
quay.io and Docker Hub that the cluster's workloads use, and the public keys everything
is verified with. A bare-metal node (here a QEMU VM) boots the stock Rocky installer with
a kickstart, pulls the edge image, and comes up running RKE2. Day-2 is `bootc upgrade`
against the same registry; rollback is built in.

Every RPM, repo index and image is signed, and the build host, the installer and the node
each refuse anything unsigned.

```
dl.rockylinux.org ─┐                          ┌─> podman build (base, edge image)
rpm.rancher.io    ─┼─> Artifact Keeper :30080 ─┼─> Rocky installer + kickstart ─> edge node
registry-1.docker.io┘   rpm-* / oci-*          └─> bootc upgrade, RKE2 image pulls
```

## Layout

| Path | What |
|---|---|
| `registry/` | Artifact Keeper (compose, rootless podman), `up.sh`, idempotent `bootstrap.sh` that creates all repos (incl. `raw-edge-keys`), enables repodata signing, mints a CI token and writes `out/edge.repo` |
| `signing/` | Key generation (cosign + RPM GPG, vendor keys), key publishing to `raw-edge-keys`, image signing helper, end-to-end `verify.sh`; keys in `signing/keys/` (gitignored) |
| `base/` | Builds the RESF SIG/Containers `rocky-bootc` recipe rootless, dnf pointed only at Artifact Keeper, pushes and cosign-signs `oci-bootc/rocky-bootc-base:10` |
| `rpms/` | `edge-site-config` spec (RKE2 config, registries.yaml, MOTD, demo manifest, insecure-registry drop-in), built and `rpmsign`ed in a Rocky container, uploaded to `rpm-edge-site` |
| `image/` | `Containerfile` for `oci-bootc/rocky-edge:10.2-<rel>` with the node's signature policy; build gate that fails on any non-Artifact-Keeper repo or key URL and on `gpgcheck=0`; `bootc container lint --fatal-warnings`; push + cosign sign |
| `deploy/` | Kickstart template (signature policy in `%pre`), pxeboot media + stage2 cache, QEMU harness: `preflight`, `vm-install`, `vm-boot`, `vm-verify`, `vm-upgrade`, `vm-upgrade-unsigned`, `vm-rollback`, `vm-all`, `vm-ssh`, `vm-status` |
| `docs/` | Source of the [documentation site](https://brandonrc.github.io/rocky-custom-baremetal-deployment/) (`mkdocs.yml`), including the lab notes `findings-*.md` and the original `PLAN.md` |

Each directory has its own README with details and the deviations from upstream docs.

## Requirements

Linux with rootless podman 5.x, skopeo, cosign, gpg, jq, QEMU and edk2-ovmf, an SSH key pair,
about 8 GB RAM free for the VM and 7 GB of disk. No sudo for the pipeline itself. `/dev/kvm`
is used when present; without it everything runs under software emulation, about 5x slower.
`make preflight` checks the host. Details: [Environment setup](https://brandonrc.github.io/rocky-custom-baremetal-deployment/environment/).

## Quick start

```bash
make preflight       # check tools, rootless podman, /dev/kvm, vm.max_map_count, SSH key, ports
make all             # Artifact Keeper, keys, base image, site RPM, edge images: built, pushed, signed, verified
make vm-all          # install the edge node, boot, verify, refuse an unsigned upgrade,
                     #   upgrade, verify, roll back, verify
make vm-ssh          # ssh -p 2222 root@localhost (key-only, root password locked)
```

Admin UI: http://localhost:30080 (user `admin`, password generated into `registry/.env`).
Generated secrets, signing keys, the kickstart with your key, VM disks and media are all
gitignored. The signing keys are PoC-grade (no passphrases).

- Every target, what it prints and what to do when it fails: [Walkthrough](https://brandonrc.github.io/rocky-custom-baremetal-deployment/walkthrough/)
- KVM and software-emulation numbers: [Timings](https://brandonrc.github.io/rocky-custom-baremetal-deployment/timings/)
- What broke along the way and how it was fixed: [Findings overview](https://brandonrc.github.io/rocky-custom-baremetal-deployment/findings/)
- Error strings and fixes: [Troubleshooting](https://brandonrc.github.io/rocky-custom-baremetal-deployment/troubleshooting/)

## License

MIT for everything in this repo. `base/upstream/rocky-bootc/` is vendored from
<https://git.resf.org/sig_containers/rocky-bootc> under its own license (see files there).
