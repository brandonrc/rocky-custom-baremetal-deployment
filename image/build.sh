#!/usr/bin/env bash
# Build the edge image for one edge-site-config release, verify it, smoke-test it.
#   SITE_RELEASE=1 image/build.sh   -> localhost/rocky-edge:<osver>-1
#   SITE_RELEASE=2 image/build.sh   -> localhost/rocky-edge:<osver>-2
# <osver> is VERSION_ID of the base image (10.2 today). Pushing is image/push.sh.
# Env: SITE_RELEASE (default 1), AK (default localhost:30080),
#      CTR_HOST (registry host seen from podman build, default host.containers.internal),
#      VM_HOST (registry host seen from the edge node, default 10.0.2.2)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
CTR_HOST="${CTR_HOST:-host.containers.internal}"
VM_HOST="${VM_HOST:-10.0.2.2}"
SITE_RELEASE="${SITE_RELEASE:-1}"
BASE="$AK/oci-bootc/rocky-bootc-base:10"
REPO_IN="$ROOT/registry/out/edge.repo.in"
WORK="$HERE/.work"
log() { echo "image: $*"; }
[[ -f "$REPO_IN" ]] || { echo "image/build.sh: $REPO_IN missing; run registry/bootstrap.sh" >&2; exit 1; }

"$HERE/setup-host.sh" >/dev/null
mkdir -p "$WORK"
sed "/^baseurl=/s/@HOST@/$CTR_HOST/" "$REPO_IN" > "$WORK/build.repo"
sed "/^baseurl=/s/@HOST@/$VM_HOST/"  "$REPO_IN" > "$WORK/edge.repo"
cp "$HERE/Containerfile" "$WORK/Containerfile"
rm -rf "$WORK/rootfs"; cp -r "$HERE/rootfs" "$WORK/rootfs"

podman pull -q --tls-verify=false "$BASE" >/dev/null
OSVER="${OSVER:-$(podman run --rm "$BASE" sh -c '. /usr/lib/os-release; echo "$VERSION_ID"')}"
LOCAL="localhost/rocky-edge:$OSVER-$SITE_RELEASE"

log "building $LOCAL from $BASE (edge-site-config release $SITE_RELEASE)"
start=$(date +%s)
podman build --tls-verify=false --pull=never \
  --build-arg BASE_IMAGE="$BASE" --build-arg SITE_RELEASE="$SITE_RELEASE" --build-arg OSVER="$OSVER" \
  -t "$LOCAL" -f "$WORK/Containerfile" "$WORK"
log "build took $(( $(date +%s) - start ))s"

# Only-Artifact-Keeper property, checked again from outside the build.
bad=$(podman run --rm "$LOCAL" sh -c "grep -rhE '^[[:space:]]*(baseurl|mirrorlist|metalink)[[:space:]]*=' /etc/yum.repos.d/ | grep -v ':30080/' || true")
[[ -z "$bad" ]] || { echo "image/build.sh: non-Artifact-Keeper repo URLs in $LOCAL: $bad" >&2; exit 1; }
log "repo check OK: /etc/yum.repos.d contains only :30080 URLs"

# Smoke test as a plain container.
podman run --rm "$LOCAL" bash -euo pipefail -c '
  rpm -q rke2-server rke2-selinux edge-site-config kernel kernel-modules-extra NetworkManager openssh-server bubblewrap
  test -x /usr/bin/bwrap
  grep -q "^d /var/log/journal " /usr/lib/tmpfiles.d/50-edge-image.conf
  bootc --version
  ls -l /usr/lib/systemd/system/rke2-server.service
  for u in rke2-server NetworkManager sshd edge-site-manifests; do printf "%s: " "$u"; systemctl is-enabled "$u"; done
  cat /etc/motd.d/edge
  cat /usr/lib/bootc/kargs.d/*.toml | grep ^kargs
  test ! -e /run/k3s
  test "$(readlink /opt)" = var/opt && test "$(readlink /usr/local)" = /var/usrlocal
  grep -h -E "^d /var/(opt|usrlocal)" /usr/lib/tmpfiles.d/*.conf
  bootc container lint --fatal-warnings'
podman image inspect "$LOCAL" --format 'image: {{.Id}} size={{.Size}} layers={{len .RootFS.Layers}}'
log "built and verified $LOCAL"
