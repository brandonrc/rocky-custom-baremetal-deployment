#!/usr/bin/env bash
# Push the locally built edge images to Artifact Keeper and move the floating tag.
#   localhost/rocky-edge:<osver>-<rel>  ->  $AK/oci-bootc/rocky-edge:<osver>-<rel>
#   $AK/oci-bootc/rocky-edge:10         ->  points at <osver>-$FLOAT_RELEASE (default 1)
# Env: RELEASES (default "1 2"), FLOAT_RELEASE (default 1), AK (default localhost:30080),
#      READY_FILE (optional path; the digest of :10 is written there after push)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AK="${AK:-localhost:30080}"
RELEASES="${RELEASES:-1 2}"
FLOAT_RELEASE="${FLOAT_RELEASE:-1}"
REPO="$AK/oci-bootc/rocky-edge"
log() { echo "push: $*"; }

"$HERE/setup-host.sh" >/dev/null
podman login --tls-verify=false -u admin --password-stdin "$AK" < "$ROOT/registry/.ak-token" >/dev/null
OSVER="${OSVER:-$(podman run --rm "$AK/oci-bootc/rocky-bootc-base:10" sh -c '. /usr/lib/os-release; echo "$VERSION_ID"')}"

for r in $RELEASES; do
  tag="$OSVER-$r"
  podman image exists "localhost/rocky-edge:$tag" || { echo "push.sh: localhost/rocky-edge:$tag not built (SITE_RELEASE=$r image/build.sh)" >&2; exit 1; }
  start=$(date +%s)
  podman push --tls-verify=false "localhost/rocky-edge:$tag" "docker://$REPO:$tag"
  log "$REPO:$tag pushed in $(( $(date +%s) - start ))s"
done

# Floating tag: registry-side copy, so :10 and :<osver>-N share one manifest digest.
skopeo copy --src-tls-verify=false --dest-tls-verify=false \
  "docker://$REPO:$OSVER-$FLOAT_RELEASE" "docker://$REPO:10"

for t in 10 $(for r in $RELEASES; do echo "$OSVER-$r"; done); do
  printf 'push: %-40s %s\n' "$REPO:$t" "$(skopeo inspect --no-creds --tls-verify=false "docker://$REPO:$t" | jq -r .Digest)"
done
if [[ -n "${READY_FILE:-}" ]]; then
  skopeo inspect --no-creds --tls-verify=false "docker://$REPO:10" | jq -r .Digest > "$READY_FILE"
  log "wrote digest of $REPO:10 to $READY_FILE"
fi
