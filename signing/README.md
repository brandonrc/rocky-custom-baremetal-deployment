# signing/ — keys and the trust model

Iteration 2 of the PoC: every artifact an edge node consumes is signed, Artifact
Keeper stores the signatures and the public keys, and every consumer verifies.
There is no `--no-signature-verification`, `gpgcheck=0` or `insecureAcceptAnything`
on any path that touches our content.

## Who signs what, where the signature lives, who verifies

| Artifact | Signed by | Signature lives in | Verified by |
|---|---|---|---|
| `edge-site-config` RPM (1.0-3, 1.0-4) | edge RPM GPG key, `rpmsign --addsign` in the build container (`rpms/build.sh`) | the RPM header | `rpm -K` at build time; dnf `gpgcheck=1` in the image build (and on the node if anyone runs dnf) |
| `rpm-edge-site` repodata | Artifact Keeper's own OpenPGP key for that repo (signing API, `sign_metadata`) | `repodata/repomd.xml.asc`, key at `repodata/repomd.xml.key` | dnf `repo_gpgcheck=1` |
| Proxied Rocky BaseOS/AppStream/extras, RKE2 common/1.36 | the vendors | RPM headers and upstream `repomd.xml.asc`, passed through unchanged by AK | dnf `gpgcheck=1` + `repo_gpgcheck=1` |
| Proxied EPEL 10, k3s (el9) | the vendors | RPM headers only (no upstream `repomd.xml.asc`) | dnf `gpgcheck=1` (`repo_gpgcheck=0`) |
| `oci-bootc/rocky-bootc-base`, `oci-bootc/rocky-edge` | edge cosign key, by digest, right after push | `oci-bootc`, tag `sha256-<digest>.sig` next to the image | podman/skopeo on the build host (`~/.config/containers/policy.json`), Anaconda (kickstart `%pre` policy), `bootc upgrade` (policy baked into the image) |
| Public keys | n/a | AK generic repo `raw-edge-keys` (anonymous read) | fetched by dnf (`gpgkey=`), kickstart `%pre` (`curl`), humans |

## Files

| Path | What |
|---|---|
| `gen-keys.sh` | Idempotent. Creates the cosign key pair and the RPM GPG key in `keys/`, exports public keys to `keys/pub/`, fetches the Rancher and EPEL 10 keys, copies Rocky's key out of the base image (reference only) |
| `publish-keys.sh` | Uploads `edge-cosign.pub`, `RPM-GPG-KEY-edge`, `RPM-GPG-KEY-Rancher`, `RPM-GPG-KEY-EPEL-10` to `raw-edge-keys`, proves anonymous download returns the same bytes, prints the URLs |
| `lib.sh` | cosign flags and helpers shared by the scripts below, `image/push.sh` and `base/build.sh` |
| `sign-image.sh` | Signs `IMAGE:TAG...` by digest (resolves the tag first), then `cosign verify`; skips digests that already verify |
| `verify.sh` | Host-side end-to-end check (keys served, cosign verify of every release tag and of the `:10` float, negative tags unsigned, build-host policy admits/rejects, repodata signatures, `rpm -K`) |
| `keys/` | **gitignored**, mode 700: `cosign.key`, `cosign.pub`, `gnupg/` (throwaway GNUPGHOME with the RPM key), `docker/config.json` (registry auth for cosign), `pub/` |

```bash
make keys           # signing/gen-keys.sh
make publish-keys   # signing/publish-keys.sh
make sign           # (re)sign base + rocky-edge release tags, no-op when already signed
make verify         # signing/verify.sh
```

Public key URLs (anonymous; from the VM use `10.0.2.2`, from a podman build `host.containers.internal`):

```
http://localhost:30080/api/v1/repositories/raw-edge-keys/download/edge-cosign.pub
http://localhost:30080/api/v1/repositories/raw-edge-keys/download/RPM-GPG-KEY-edge
http://localhost:30080/api/v1/repositories/raw-edge-keys/download/RPM-GPG-KEY-Rancher
http://localhost:30080/api/v1/repositories/raw-edge-keys/download/RPM-GPG-KEY-EPEL-10
http://localhost:30080/rpm/rpm-edge-site/repodata/repomd.xml.key      (AK's repodata key)
```

## PoC shortcuts (not for production)

- **The cosign key has an empty password** (`COSIGN_PASSWORD=""`). cosign still writes it
  as an encrypted (scrypt + secretbox) PEM, but with an empty passphrase. Use a real
  passphrase, a KMS URI (`--key awskms://...`, `hashivault://...`) or a hardware key.
- **The RPM key has no passphrase** and lives in a plain GNUPGHOME on the build host.
  The build container gets it read-only and copies it into a throwaway homedir.
- Keys never expire and there is no rotation procedure. Rotating = new key, re-sign
  (cosign allows several signatures per digest), ship the new public key in an image
  *signed by the old key*, then drop the old key from the policy.
- Key pairs, not keyless: there is no OIDC identity provider or Rekor on an edge network,
  so signatures carry no transparency-log entry (`--tlog-upload=false`), and
  verification uses `--insecure-ignore-tlog` (cosign) / no `rekorPublicKeyPath` (policy.json).
- Transport is still plain HTTP (`insecure = true` registries). Signatures protect
  content integrity and origin; TLS (confidentiality, and protection of the unsigned
  bits such as tag-to-digest resolution and repo metadata for EPEL/k3s) is a separate step.

## Things that bit (details in docs/findings-signing.md)

- cosign 3.x signs in the new Sigstore bundle format via the OCI referrers API by default.
  Artifact Keeper stores that fine, but containers-image (podman, skopeo, bootc, Anaconda)
  only reads the classic `sha256-<digest>.sig` attachment. `lib.sh` therefore passes the
  hidden/deprecated `--new-bundle-format=false --use-signing-config=false --tlog-upload=false`.
- cosign records a **tag-less** identity (`localhost:30080/oci-bootc/rocky-edge`). The
  default `signedIdentity` (`matchRepoDigestOrExact`) never accepts that, so policies use
  `matchRepository` (build host) or `exactRepository` (node, because the node sees the
  registry as `10.0.2.2:30080` while the signer pushed to `localhost:30080`).
- Signatures bind to the manifest digest. A "copy" that keeps the digest (plain
  `skopeo copy` of the same image under a new tag) is still signed; to produce a
  genuinely unsigned test image you must change the digest (new label, other manifest format).
- cosign does not read podman's `auth.json`; it gets its own `DOCKER_CONFIG`.
