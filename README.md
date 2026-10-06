# Rocky Linux image mode on bare metal, with Artifact Keeper as the source of truth

Proof of concept behind the OpenTeams engineering blog post
*Rocky Linux Image Mode on Bare Metal, with Artifact Keeper as the Source of Truth*.

One [Artifact Keeper](https://github.com/artifact-keeper/artifact-keeper) instance holds
everything an edge node boots from: Rocky Linux 10 and EPEL RPMs (proxy repos), RKE2
RPMs (proxy), our own `edge-site-config` RPM (hosted), a self-built Rocky 10 bootc base
image and the edge image layered on it (hosted OCI), pull-through proxies for
quay.io and Docker Hub that the cluster's workloads use, and the public keys everything
is verified with. A bare-metal node (here a QEMU VM) boots the stock Rocky installer with
a kickstart, pulls the edge image, and comes up running RKE2. Day-2 is `bootc upgrade`
against the same registry; rollback is built in.

Iteration 2 signs everything and verifies everywhere: our RPMs are GPG-signed, Artifact
Keeper signs our repo metadata, vendor signatures pass through the proxies, and every
image is cosign-signed by digest. dnf runs with `gpgcheck=1` (plus `repo_gpgcheck=1`
where the metadata is signed), and podman on the build host, Anaconda and `bootc upgrade`
on the node all refuse unsigned images through `containers-policy.json`
(see `signing/README.md` and `docs/findings-signing.md`).

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
| `deploy/` | Kickstart template (signature policy in `%pre`), pxeboot media + stage2 cache, QEMU harness: `vm-install`, `vm-boot`, `vm-verify`, `vm-upgrade`, `vm-upgrade-unsigned`, `vm-rollback`, `vm-ssh`, `vm-status` |
| `docs/` | `PLAN.md` (design), `findings-image.md`, `findings-deploy.md` and `findings-signing.md` (everything that broke, with exact errors and timings) |

Each directory has its own README with details and the deviations from upstream docs.

## Requirements

- Linux with rootless podman 5.x (`podman compose` or docker-compose), skopeo, cosign
  (tested with 3.1.3), gpg, jq, qemu-system-x86_64, edk2-ovmf, curl, python3. No sudo is
  needed anywhere. `/dev/kvm` is used when present; otherwise QEMU falls back to software
  emulation (an install takes ~10 min instead of ~1, power-on to a Ready cluster ~17 min
  instead of ~3).
- An SSH key at `~/.ssh/id_ed25519.pub` (injected into the node via kickstart `sshkey`).
- About 8 GB RAM free for the VM and 7 GB of disk for images and media (incl. the cached
  750 MB installer stage2).

## Quick start

```bash
make registry-up     # start Artifact Keeper on http://localhost:30080, create repos + token,
                     #   enable repodata signing on rpm-edge-site
make keys            # cosign key pair + RPM GPG key (signing/keys/, gitignored), vendor keys
make publish-keys    # public keys -> raw-edge-keys repo (anonymous download)
make base            # build the Rocky 10 bootc base rootless, push, cosign-sign (~4 min)
make rpm             # build + rpmsign edge-site-config 1.0-3 and 1.0-4, upload
make image push      # build rocky-edge:10.2-3 and :10.2-4, push, sign, point :10 at 10.2-3
make unsigned-test   # an UNSIGNED rocky-edge:unsigned-test for the negative tests
make verify          # keys, cosign signatures, build-host policy, repodata + RPM signatures
make vm-install      # kickstart install from oci-bootc/rocky-edge:10 into deploy/state/ (~1 min with KVM)
make vm-boot         # boot it, wait for ssh, show bootc status + signature policy / node Ready
make vm-verify       # nginx-demo Running and its digest cached in oci-dockerhub-proxy
make vm-upgrade-unsigned  # negative: :10 -> unsigned-test, bootc upgrade must be refused
make vm-upgrade      # promote :10.2-4 -> :10, bootc upgrade, reboot, verify
make vm-rollback     # bootc rollback, reboot, verify
make vm-ssh          # ssh -p 2222 root@localhost (key-only, root password locked)
```

`make all` runs everything up to `verify`. Negative install test:
`make vm-install IMAGE=rocky-edge:unsigned-test` must stop with
`A signature was required, but no signature exists` (it aborts in about 45 s).

Timings with KVM (6 vCPU, 8 GiB) vs software emulation, from `docs/findings-signing.md`:

| Stage | KVM | TCG |
|---|---|---|
| kickstart install | 65 s | 601 s |
| power-on to ssh / to RKE2 node Ready | 25 s / 86 s | 52 s / 324 s |
| day-2 `bootc upgrade` pull+stage / reboot to ssh | 6 s / 20 s | 69 s / 148 s |
| rollback reboot to ssh | 101 s | 148 s |

Admin UI: http://localhost:30080 (user `admin`, password generated into `registry/.env`).
Generated secrets, signing keys, the kickstart with your key, VM disks and media are all
gitignored. The signing keys are PoC-grade (no passphrases); see `signing/README.md`.

## What broke along the way

See `docs/findings-image.md`, `docs/findings-deploy.md` and `docs/findings-signing.md`. Highlights:

- Rocky publishes no official bootc base image; the RESF recipe builds rootless as-is.
- The `bootc` kickstart command on Rocky 10.2 mislabels `/root/.ssh` and `/etc/resolv.conf`; use `ostreecontainer`.
- `/opt` is read-only in the base, so RKE2's CNI installer fails; link it to `var/opt`.
- The minimal base lacks `bubblewrap`, so `bootc upgrade` silently reverts at finalize time.
- Artifact Keeper's compose defaults refuse to start until you generate secrets; repos are private unless `is_public`; the OCI registry is path-based (`host:30080/<repo>/<image>`).
- cosign 3's default signature format (bundles via the OCI referrers API) is invisible to podman/skopeo/bootc/Anaconda; sign in the legacy `.sig` format.
- cosign signatures carry a tag-less identity that the default `containers-policy.json` identity rule rejects; use `matchRepository`/`exactRepository`.
- Removing `--no-signature-verification` from the kickstart changes nothing by itself; the installer's `policy.json` is what enforces signatures (for `bootc upgrade` too).

## License

MIT for everything in this repo. `base/upstream/rocky-bootc/` is vendored from
<https://git.resf.org/sig_containers/rocky-bootc> under its own license (see files there).
