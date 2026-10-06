# Walkthrough

The whole pipeline is driven by `make` from the repository root. Every target is
re-runnable and wraps a script of the same purpose; `make help` lists them. Prerequisites
are on [Setting up the environment](environment.md).

```bash
git clone https://github.com/brandonrc/rocky-custom-baremetal-deployment
cd rocky-custom-baremetal-deployment
make all            # registry-up keys publish-keys base rpm image push unsigned-test sign verify
make vm-install vm-boot vm-verify vm-upgrade-unsigned vm-upgrade vm-verify vm-rollback vm-verify
```

The sections below go through the same sequence one target at a time. Timings are from the
iteration 2 run with KVM unless noted; see [Timings](timings.md) for TCG.

## 1. `make registry-up`

Runs `registry/up.sh` then `registry/bootstrap.sh`.

- `up.sh` copies `.env.example` to `registry/.env` on the first run and fills in the
  secrets Artifact Keeper refuses to start without (`JWT_SECRET`, `AK_WEBHOOK_SECRET_KEY`,
  a random `ADMIN_PASSWORD`), starts the stack with `podman compose`, and waits for
  `/readyz` (about 60 s cold).
- `bootstrap.sh` creates the 12 repositories (all `is_public: true`), creates a server-side
  GPG key and turns on `sign_metadata` for `rpm-edge-site`, mints or reuses a CI token in
  `registry/.ak-token`, and writes `registry/out/edge.repo`, `edge.repo.in` and
  `README-urls.md`. Existing repos and signing config are detected and left alone.

Expect: the web UI at <http://localhost:30080> (user `admin`, password in `registry/.env`)
and a re-run that reports `repodata signing already enabled on rpm-edge-site (key 56f1a82f...)`.

## 2. `make keys`

Runs `signing/gen-keys.sh`. Creates, if missing:

- a cosign key pair (`signing/keys/cosign.key`, `.pub`; empty password, PoC only),
- an RSA 4096 sign-only RPM GPG key in a throwaway `GNUPGHOME` (`signing/keys/gnupg`),
- public copies in `signing/keys/pub/`, plus the Rancher and EPEL 10 vendor keys and a
  reference copy of Rocky's key from the base image.

Re-running keeps existing keys.

## 3. `make publish-keys`

Runs `signing/publish-keys.sh`: uploads `edge-cosign.pub`, `RPM-GPG-KEY-edge`,
`RPM-GPG-KEY-Rancher` and `RPM-GPG-KEY-EPEL-10` to the generic repo `raw-edge-keys`, then
downloads each one anonymously and compares bytes. The keys are served at
`http://<host>:30080/api/v1/repositories/raw-edge-keys/download/<file>`.

## 4. `make base`

Runs `base/build.sh` (about 3.5 to 4 min). It stages the vendored RESF `rocky-bootc` recipe
plus our `Containerfile` and an Artifact-Keeper-only repo file into `base/.work/ctx`, then
builds rootless:

- the builder is `localhost:30080/oci-quay-proxy/rockylinux/rockylinux:10`;
- its `/etc/yum.repos.d` is replaced with the three `rpm-rocky10-*` repos (gpgcheck and
  repo_gpgcheck on) before the first `dnf install`, so the whole rootfs comes through
  Artifact Keeper;
- `MANIFEST=minimal` (242 RPMs, 792 MB), not upstream's `standard`, which would enable
  automatic fetch-apply-reboot;
- `--no-cache` always (the final stage deletes its own input archive).

Then `bootc container lint`, push (`--remove-signatures`) to
`oci-bootc/rocky-bootc-base:10-YYYYMMDD` and `:10`, and cosign-sign the digest. It skips the
build if `localhost/rocky-bootc-base:10` already exists; `make base-rebuild` forces it.

## 5. `make rpm`

`rpms/build.sh` builds `edge-site-config` releases 3 and 4 with `rpmbuild` in a Rocky 10
container (dnf restricted to the Artifact Keeper proxies, gpg-checked), signs them with
`rpmsign`, and fails unless `rpm -K` prints `digests signatures OK`. `rpms/upload.sh` PUTs
them to `rpm-edge-site` and checks that the server-generated `primary.xml.gz` lists them.
Build and sign take about 7 s. Re-uploading an existing file name returns HTTP 409 and is
left as is: bump the release instead of rebuilding.

## 6. `make image push`

`make image` runs `image/setup-host.sh` (user-level policy, see
[environment](environment.md#user-level-files-written-by-imagesetup-hostsh)) and builds
`localhost/rocky-edge:10.2-3` and `:10.2-4`. The build pulls the base **through the
signature policy**, so an unsigned base stops it. It deletes the base's stock repo files,
installs NetworkManager, openssh-server, bubblewrap, `kernel-modules-extra` (pinned to the
base kernel), `rke2-server` and `rke2-selinux`, then the site RPM in a separate layer,
re-links `/opt` to `var/opt`, copies in the node's `policy.json`, `registries.d` entry and
cosign public key, and fails on any repo or key URL that is not Artifact Keeper or any
`gpgcheck=0`. A smoke test runs the image as a container, and
`bootc container lint --fatal-warnings` must pass (13 passed, 1 skipped).

`make push` pushes both tags, cosign-signs each digest, and moves the floating `:10` to
`10.2-3` with a registry-side `skopeo copy` (same digest, so it is covered by the same
signature). About 27 s per build that re-runs the OS layer, 8 s for the second release,
1-2 s per push and 1 s per signature.

!!! note
    `make push` always re-points `:10` at `REL` (default 3). Running it after a day-2
    promote moves the fleet's tag back.

## 7. `make unsigned-test`

Builds `rocky-edge:unsigned-test` (release 4 plus the label `edge.test=unsigned`, so it has
a new digest) and pushes it **without** signing. It is the input to both negative VM tests.
A plain retag of a signed image would not work as a negative test: signatures belong to
digests, so an identical image under a new tag is still signed.

## 8. `make sign` and `make verify`

`make sign` (re)signs the base and every release tag; it is a no-op when the digests already
verify. `make verify` runs `signing/verify.sh`, which checks that:

- every public key is served anonymously and matches the local copy;
- `cosign verify` passes for each release tag and for `:10`, and fails for the negative tags;
- the build-host policy admits the signed base and rejects the unsigned one;
- `repomd.xml.asc` verifies for `rpm-edge-site` (Artifact Keeper's key) and for the proxied
  Rocky and RKE2 repos (vendor keys);
- `rpm -K` passes for the signed RPMs.

## 9. `make vm-install`

`deploy/vm-install.sh` (65 s with KVM, about 10 min under TCG):

1. Fetches and sha256-checks the Rocky 10.2 pxeboot `vmlinuz`, `initrd.img` and stage2
   `install.img` into `deploy/cache/` (first run only).
2. Renders `deploy/ks.cfg.in` into `deploy/state/www/ks.cfg` with your public key, and serves
   it plus the stage2 on port 8000.
3. Creates a fresh 40 GB qcow2 and OVMF vars and starts QEMU headless with
   `inst.ks=http://10.0.2.2:8000/ks.cfg`.
4. Follows Anaconda's milestones on the serial console: `Starting installer`,
   `Installing the software`, `Performing post-installation`, `Installation complete`.

During the install, kickstart `%pre` writes the installer's `policy.json` (default `reject`,
cosign signature required for `rocky-edge`), fetches the key from `raw-edge-keys`, and
`ostreecontainer` pulls `10.0.2.2:30080/oci-bootc/rocky-edge:10`.

**Negative test:** `make vm-install IMAGE=rocky-edge:unsigned-test` must stop with

```text
error: Performing deployment: Preparing import: Fetching manifest: failed to
invoke method OpenImage: A signature was required, but no signature exists
```

`vm-install.sh` watches for that and aborts in about 45 s (Anaconda would otherwise wait for
ENTER forever).

## 10. `make vm-boot`

Boots the disk in the background with ssh forwarded to port 2222, waits for ssh (25 s KVM,
52 s TCG) and for the RKE2 node to be Ready (another 61 s KVM, about 4.5 min TCG), then
prints `bootc status` (image `10.0.2.2:30080/oci-bootc/rocky-edge:10`, version `10.2-3`),
`getenforce` (`Enforcing`), the insecure-registry drop-ins and the node's signature policy.

## 11. `make vm-verify`

Waits until `rke2-server` is active and every `nginx-demo` pod is Running and Ready, then
checks that the pod's image digest (`docker.io/library/nginx:alpine`) exists in Artifact
Keeper's `oci-dockerhub-proxy`. That is the proof the workload came through the registry:
RKE2's `registries.yaml` mirrors all of `docker.io` to `http://10.0.2.2:30080` with a
`rewrite` to `oci-dockerhub-proxy/$1`. The Deployment's label
`edge-site/config-release=N` shows which site-config release is live.

## 12. `make vm-upgrade-unsigned` (day-2 negative)

Copies `rocky-edge:unsigned-test` onto `:10` (with `skopeo copy --insecure-policy`, because
the build-host policy would refuse it too), runs `bootc upgrade` on the node, and requires
it to fail:

```text
error: Upgrading: Preparing import: Fetching manifest: failed to invoke method OpenImage:
A signature was required, but no signature exists
```

It then checks that nothing is staged, the node is still on its image and `rke2-server` is
active, and restores `:10` to the signed digest.

## 13. `make vm-upgrade` (day 2)

Promotes `rocky-edge:10.2-4` to `:10` (a 1 s registry-side tag copy; no re-signing needed),
runs `bootc upgrade` (`layers needed: 3 (7.8 MB)`, 6 s with KVM), reboots (20 s to ssh) and
asserts that the booted digest is the staged one and the rollback slot holds the old one.
Expect the MOTD to change to `edge-site-config 1.0-4.el10: day-2 update via bootc upgrade`
and, after a `vm-verify`, `nginx-demo ... edge-site/config-release=4`. If the booted digest
does not match, the script prints the `ostree-boot-complete` journal, which is where a failed
finalize shows up.

Override the source with `PROMOTE_FROM=` (empty means just `bootc upgrade` without retagging).

## 14. `make vm-rollback`

`bootc rollback`, reboot (about 101 s to ssh with KVM), and assert that booted and rollback
swapped. The MOTD goes back to `1.0-3.el10: initial site configuration` and, because
`edge-site-manifests.service` re-seeds the RKE2 manifests from the booted image on every boot,
the Deployment goes back to `config-release=3`. Running it a second time swaps forward again.

## Other targets

| Target | What |
|---|---|
| `make vm-ssh` | `ssh -p 2222 root@localhost` (key only) |
| `make vm-status` | one-screen summary of the VM and `bootc status` |
| `make vm-stop` | clean ACPI poweroff (about 90 s under TCG) |
| `make vm-clean` | stop and delete `deploy/state/` (`CLEAN_CACHE=1` also drops the media cache) |
| `make promote REL=4` | move `:10` to another release without touching the VM |
| `make registry-down` | stop Artifact Keeper, volumes kept (`registry/down.sh -v` deletes them) |
| `make clean` | remove local build scratch (`base/.work`, `rpms/.work`, `rpms/out`, `image/.work`) |

Every variable in `deploy/lib.sh` (`IMAGE`, `REGISTRY`, `VM_SMP`, `VM_MEM`, `SSH_PORT`,
`STAGE2`, timeouts, ...) can be overridden on the `make` command line; the full table is in
`deploy/README.md`.
