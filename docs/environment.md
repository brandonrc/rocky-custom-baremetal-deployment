# Setting up the environment

Everything in this repository runs as an ordinary user: rootless podman for Artifact
Keeper and all image builds, and an unprivileged QEMU process for the "bare-metal" node.
**Nothing needs sudo.** The reference workstation was Fedora 44 with 24 cores and 125 GB
RAM; any recent Linux with the tools below should work.

## Host requirements

| Tool | Used for | Tested with |
|---|---|---|
| podman 5.x (rootless) | Artifact Keeper stack, base/RPM/image builds | 5.8.7 |
| `podman compose` or docker-compose | starting the Artifact Keeper compose file | `podman compose` delegating to docker-compose v5.5.1 |
| skopeo | inspecting, copying and promoting tags in the registry | 1.22.3 |
| cosign | signing and verifying images | 3.1.3 (see the note on formats below) |
| gpg | RPM signing key, repodata signature checks | GnuPG 2.4.9 |
| jq, curl, python3 | scripts, API calls, serving the kickstart | |
| qemu-system-x86_64 | the edge node VM | QEMU 10.2.2 |
| edk2-ovmf | UEFI firmware for the VM | |
| uv | building this documentation site | 0.12 |

Other requirements:

- **SSH key** at `~/.ssh/id_ed25519.pub` (override with `SSH_KEY=`). It is injected into
  the node with the kickstart `sshkey` command; root's password is locked, so this key is
  the only way in.
- **RAM:** about 8 GB free for the VM (6 vCPU, 8 GiB by default; `VM_SMP`, `VM_MEM`), plus
  what the Artifact Keeper stack uses (Postgres, OpenSearch, backend, web, Caddy).
- **Disk:** about 7 GB for images and install media (including the cached 750 MB installer
  stage2), plus the VM's 40 GB sparse qcow2 (`VM_DISK_SIZE`) and Artifact Keeper's volumes.

!!! note "cosign version"
    cosign 3 signs in the Sigstore bundle format via the OCI referrers API by default.
    podman, skopeo, bootc and Anaconda cannot see that format, so `signing/lib.sh` passes
    the deprecated `--new-bundle-format=false --use-signing-config=false --tlog-upload=false`
    flags. Pin cosign (3.1.3 works) until containers-image reads bundles. Details in
    [Findings: signing](findings-signing.md#5-image-signing-and-how-ak-stores-cosign-signatures).

## KVM: check it, enable it, or live without it

The VM harness uses hardware virtualization when it can. `deploy/lib.sh` picks the
accelerator by itself:

```bash
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  echo "-accel kvm -cpu host"
else
  echo "-accel tcg,thread=multi -cpu max"
fi
```

### Check

```bash
ls -l /dev/kvm                      # should exist and be rw for your user (e.g. crw-rw-rw-)
grep -cE 'svm|vmx' /proc/cpuinfo    # >0: the CPU supports AMD-V (svm) or VT-x (vmx)
journalctl -k -b | grep -iE 'kvm|svm|vmx'
```

If `/dev/kvm` is missing on an AMD machine, look for this line in the kernel log:

```text
kvm_amd: SVM disabled (by BIOS) in MSR_VM_CR
```

That is the tell that the CPU supports virtualization but the firmware has it switched
off. The fix is in the firmware setup, not in Linux: enable **SVM Mode** / **AMD-V** (AMD)
or **Intel Virtualization Technology (VT-x)** (Intel), save, and reboot. After that
`/dev/kvm` appears and the `kvm_amd` or `kvm_intel` module loads. On most distributions
`/dev/kvm` is world read-write (`crw-rw-rw-`) or owned by the `kvm` group; if it is
group-only, your user must be in that group (that one change does need an administrator).

### Without KVM: QEMU TCG

Without `/dev/kvm`, QEMU falls back to TCG, its software CPU emulator
(`-accel tcg,thread=multi -cpu max`). Everything still works, and iteration 1 of this
project ran entirely under TCG, but it is roughly 5 to 10 times slower:

| Stage | KVM | TCG |
|---|---|---|
| kickstart install | 65 s | 601 s |
| power-on to ssh | 25 s | 52 s |
| ssh to RKE2 node Ready | 61 s | 272 s |
| day-2 `bootc upgrade` pull + stage | 6 s | 69 s |
| upgrade reboot to ssh | 20 s | 148 s |
| rollback reboot to ssh | 101 s | 148 s |
| power-on to working cluster | about 3 min | about 17 min |

(From [Findings: signing](findings-signing.md#timings-kvm-this-run-vs-tcg-iteration-1-run-3);
the full breakdown is on the [Timings](timings.md) page.) The harness timeouts
(`INSTALL_TIMEOUT=2400`, `WAIT_READY=1200`) are sized for TCG. Under TCG a clean shutdown
takes about 90 s and Anaconda takes about 5 minutes just to start.

## Rootless podman

- **Compose.** `registry/up.sh` uses `podman compose`, which on the reference host delegates
  to docker-compose talking to the rootless podman socket. The stock Artifact Keeper compose
  file (fixed `172.30.0.0/24` network, `depends_on.required: false`,
  `service_completed_successfully`, `!reset` in the override) worked without changes.
  Make sure the user podman socket is running (`systemctl --user enable --now podman.socket`)
  if your compose provider needs it.
- **Networking.** Rootless podman 5 uses **pasta**. From inside a container or a
  `podman build`, the host is `host.containers.internal` (it resolved to `169.254.1.2` on the
  reference host); every build in this repository reaches Artifact Keeper as
  `host.containers.internal:30080`.
- **Short names.** Rootless podman's `short-name-mode = "enforcing"` matched a short
  `postgres:18-alpine` against an unrelated locally cached image, so the compose override
  fully qualifies every image (`docker.io/library/...`).
- **OpenSearch** needs `vm.max_map_count` high enough; it already was on the reference host.
  If it is not, that sysctl is the one thing an administrator would have to change.
- **Builds** that run the RESF recipe need `--security-opt=label=disable --cap-add=all
  --device /dev/fuse`, which rootless podman allows as is.

## User-level files written by `image/setup-host.sh`

The build host verifies the base image's signature before building on it. `image/setup-host.sh`
(run by the image build) writes only under `${XDG_CONFIG_HOME:-~/.config}/containers/`:

| File | Content | Why |
|---|---|---|
| `registries.conf.d/50-artifact-keeper-local.conf` | `[[registry]] location = "localhost:30080"`, `insecure = true` | Artifact Keeper is plain HTTP; this makes `FROM`, pull and push work without `--tls-verify=false` |
| `policy.json` | a copy of `/etc/containers/policy.json` (or an `insecureAcceptAnything` default if there is none) plus `transports.docker["localhost:30080/oci-bootc"] = sigstoreSigned` with `keyPath` = `signing/keys/pub/edge-cosign.pub` and `signedIdentity: matchRepository` | images under `oci-bootc` must carry our cosign signature |
| `registries.d/ak-oci-bootc.yaml` | `docker: localhost:30080/oci-bootc: use-sigstore-attachments: true` | tells containers-image to look for cosign's `sha256-<digest>.sig` tags |
| `registries.d/*.yaml` (symlinks) | links to each `/etc/containers/registries.d/*.yaml` | see the warning below |

!!! warning "User-level files replace the system ones"
    A user-level `~/.config/containers/policy.json` **replaces** `/etc/containers/policy.json`
    for your user, and a user-level `registries.d/` **replaces** `/etc/containers/registries.d/`.
    That is why the script starts from a copy of the system policy and symlinks the system
    `registries.d` files next to its own. If your system policy changes later, your copy
    does not follow it.

The `matchRepository` identity is deliberate: cosign records a tag-less identity
(`localhost:30080/oci-bootc/rocky-edge`), and the default `matchRepoDigestOrExact` rejects
it with `Signature for identity ... is not accepted`.

### Undoing it

```bash
C="${XDG_CONFIG_HOME:-$HOME/.config}/containers"
rm -f "$C/registries.conf.d/50-artifact-keeper-local.conf"
rm -f "$C/registries.d/ak-oci-bootc.yaml"
# the symlinks to /etc/containers/registries.d/*.yaml (only the links, not the targets)
find "$C/registries.d" -maxdepth 1 -type l -lname '/etc/containers/registries.d/*' -delete
rmdir "$C/registries.d" 2>/dev/null || true
# policy.json: delete it if setup-host.sh created it (the system policy applies again) ...
rm -f "$C/policy.json"
# ... or, if you had your own before, just drop the added scope:
# jq 'del(.transports.docker["localhost:30080/oci-bootc"])' "$C/policy.json" > p && mv p "$C/policy.json"
```

## Other generated state (all gitignored)

| Path | What |
|---|---|
| `registry/.env` | admin password (user `admin`), JWT secret, webhook key, generated by `up.sh` (mode 600) |
| `registry/.ak-token` | CI API token (`read:artifacts`, `write:artifacts`, 30 days), reused while valid |
| `registry/out/` | generated `edge.repo`, `edge.repo.in`, `README-urls.md` |
| `signing/keys/` | cosign key pair, RPM GPG home, cosign's registry auth, public keys (mode 700; PoC keys have no passphrase) |
| `deploy/cache/` | Rocky 10.2 pxeboot `vmlinuz`, `initrd.img`, stage2 `install.img`, sha256-checked |
| `deploy/state/` | VM disk, OVMF vars, serial logs, `timings.log`, rendered kickstart (contains your public key) |

`./registry/down.sh -v` deletes Artifact Keeper's volumes; `make vm-clean` deletes
`deploy/state/` (`CLEAN_CACHE=1` also drops the media cache); `make clean` removes the
local build scratch directories.

## Ports

| Port | Bound by | Use |
|---|---|---|
| `30080` | Caddy in the Artifact Keeper stack | everything: web UI, `/api/v1`, `/rpm/<key>`, OCI `/v2`. The VM reaches it as `10.0.2.2:30080` |
| `30443` | Caddy | HTTPS with Caddy's internal CA for `localhost`; not used here |
| `8000` | `deploy/serve-ks.sh` (`python3 -m http.server` on `0.0.0.0`) | kickstart and the cached installer stage2, during `vm-install` only |
| `2222` | QEMU user-mode `hostfwd` | ssh to the node: `ssh -p 2222 root@localhost` (`make vm-ssh`) |
| `30090` | inside the VM | the nginx-demo NodePort (not forwarded to the host by default) |

Change them with `HTTP_PORT` / `HTTPS_PORT` in `registry/.env`, and `KS_PORT` / `SSH_PORT`
for the harness. Postgres, OpenSearch, the backend (8080) and the web UI (3000) are only
reachable on the compose network; the stock compose file publishes Postgres and
OpenSearch on the host, and the override in `registry/compose/compose.override.yml` removes that.
