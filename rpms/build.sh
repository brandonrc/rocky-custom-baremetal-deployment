#!/usr/bin/env bash
# Build edge-site-config-1.0-{1,2} with rpmbuild inside a rootless Rocky 10
# container. The container image comes through the Artifact Keeper quay.io proxy
# and its dnf uses only the Artifact Keeper Rocky proxies.
# Output: rpms/out/*.rpm
# Env: RELEASES (default "1 2"), AK (default localhost:30080),
#      CTR_HOST (default host.containers.internal)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
CTR_HOST="${CTR_HOST:-host.containers.internal}"
RELEASES="${RELEASES:-1 2}"
BUILDER="$AK/oci-quay-proxy/rockylinux/rockylinux:10"
REPO_IN="$ROOT/registry/out/edge.repo.in"
OUT="$HERE/out"
WORK="$HERE/.work"
[[ -f "$REPO_IN" ]] || { echo "rpms/build.sh: $REPO_IN missing; run registry/bootstrap.sh" >&2; exit 1; }

mkdir -p "$OUT" "$WORK"
sed "/^baseurl=/s/@HOST@/$CTR_HOST/" "$REPO_IN" > "$WORK/edge.repo"

podman pull -q --tls-verify=false "$BUILDER" >/dev/null
start=$(date +%s)
podman run --rm --security-opt label=disable \
  -v "$HERE/edge-site-config:/src:ro" -v "$OUT:/out" -v "$WORK/edge.repo:/tmp/edge.repo:ro" \
  -e RELEASES="$RELEASES" "$BUILDER" bash -euo pipefail -c '
    rm -f /etc/yum.repos.d/*.repo
    cp /tmp/edge.repo /etc/yum.repos.d/edge.repo
    dnf -q -y --disablerepo="*" --enablerepo="rpm-rocky10-*" install rpm-build systemd-rpm-macros
    for r in $RELEASES; do
      rpmbuild -bb --define "_sourcedir /src" --define "_rpmdir /out" \
               --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
               --define "rel $r" /src/edge-site-config.spec
    done
    chown -R "$(stat -c %u:%g /out)" /out'
echo "rpms: built in $(( $(date +%s) - start ))s:"
ls -1 "$OUT"/*.rpm
