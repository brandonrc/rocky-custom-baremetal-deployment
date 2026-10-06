#!/usr/bin/env bash
# Idempotently configure Artifact Keeper for the edge PoC:
#   - creates the rpm-* and oci-* repositories (skips any that already exist)
#   - mints a CI API token into .ak-token (reused if it still authenticates)
#   - writes out/edge.repo (+ out/edge.repo.in template) and out/README-urls.md
#
# Env:
#   AK_URL  API/registry base URL used by this script (default http://localhost:$HTTP_PORT)
#   HOST    hostname baked into out/edge.repo baseurls (default localhost;
#           use 10.0.2.2 from a QEMU user-net VM, host.containers.internal
#           from a podman build/run)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
TOKEN_FILE="$HERE/.ak-token"
OUT="$HERE/out"

[[ -f "$ENV_FILE" ]] || { echo "bootstrap.sh: $ENV_FILE missing; run ./up.sh first" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a
HTTP_PORT="${HTTP_PORT:-30080}"
AK_URL="${AK_URL:-http://localhost:${HTTP_PORT}}"
HOST="${HOST:-localhost}"
command -v jq >/dev/null || { echo "bootstrap.sh: jq is required" >&2; exit 1; }

log() { echo "bootstrap: $*"; }

curl -fsS "$AK_URL/readyz" >/dev/null || { echo "bootstrap.sh: $AK_URL/readyz not ready" >&2; exit 1; }

# --- login ------------------------------------------------------------------
login_body=$(jq -nc --arg u admin --arg p "$ADMIN_PASSWORD" '{username:$u,password:$p}')
JWT=$(curl -fsS -X POST "$AK_URL/api/v1/auth/login" \
        -H 'Content-Type: application/json' -d "$login_body" | jq -r .access_token)
[[ -n "$JWT" && "$JWT" != null ]] || { echo "bootstrap.sh: login failed" >&2; exit 1; }
log "logged in as admin"

api() { # api METHOD PATH [JSON]
  local m=$1 p=$2; shift 2
  curl -sS -X "$m" "$AK_URL/api/v1$p" -H "Authorization: Bearer $JWT" \
       -H 'Content-Type: application/json' "$@"
}

# --- repositories -------------------------------------------------------------
# key|format|repo_type|upstream_url|display name
REPOS=(
  "rpm-rocky10-baseos|rpm|remote|https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/|Rocky Linux 10 BaseOS (proxy)"
  "rpm-rocky10-appstream|rpm|remote|https://dl.rockylinux.org/pub/rocky/10/AppStream/x86_64/os/|Rocky Linux 10 AppStream (proxy)"
  "rpm-rocky10-extras|rpm|remote|https://dl.rockylinux.org/pub/rocky/10/extras/x86_64/os/|Rocky Linux 10 extras (proxy)"
  "rpm-epel10|rpm|remote|https://dl.fedoraproject.org/pub/epel/10/Everything/x86_64/|EPEL 10 Everything (proxy)"
  # Rancher publishes no el10 path; centos/9 only carries k3s-selinux (el9 build).
  "rpm-k3s|rpm|remote|https://rpm.rancher.io/k3s/stable/common/centos/9/noarch/|Rancher k3s stable (k3s-selinux, el9) (proxy)"
  # RKE2 (EL10 builds). common = rke2-selinux/rke2-common deps (noarch); the minor
  # repo carries rke2-server/agent. 1.36 is the minor of the "stable" channel at
  # https://update.rke2.io/v1-release/channels on 2026-10-05 (1.37 = "latest").
  "rpm-rke2-common|rpm|remote|https://rpm.rancher.io/rke2/stable/common/centos/10/noarch/|Rancher RKE2 common EL10 (proxy)"
  "rpm-rke2-1.36|rpm|remote|https://rpm.rancher.io/rke2/stable/1.36/centos/10/x86_64/|Rancher RKE2 1.36 EL10 (proxy)"
  "rpm-edge-site|rpm|local||Edge site custom RPMs"
  "oci-bootc|docker|local||bootc images"
  "oci-quay-proxy|docker|remote|https://quay.io|quay.io (proxy)"
  "oci-dockerhub-proxy|docker|remote|https://registry-1.docker.io|Docker Hub (proxy)"
)

for spec in "${REPOS[@]}"; do
  IFS='|' read -r key format rtype upstream name <<<"$spec"
  code=$(api GET "/repositories/$key" -o /dev/null -w '%{http_code}')
  if [[ "$code" == 200 ]]; then
    log "repo $key exists, skipping"; continue
  fi
  body=$(jq -nc --arg k "$key" --arg n "$name" --arg f "$format" --arg t "$rtype" --arg u "$upstream" \
    '{key:$k,name:$n,format:$f,repo_type:$t,is_public:true}
     + (if $u != "" then {upstream_url:$u} else {} end)')
  resp=$(api POST /repositories -d "$body" -w '\n%{http_code}')
  code=${resp##*$'\n'}
  if [[ "$code" =~ ^20 ]]; then
    log "repo $key created ($format/$rtype${upstream:+ -> $upstream})"
  else
    echo "bootstrap.sh: creating $key failed: HTTP $code ${resp%$'\n'*}" >&2; exit 1
  fi
done

# --- CI API token ---------------------------------------------------------------
token_ok() {
  [[ -s "$TOKEN_FILE" ]] || return 1
  [[ "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
        "$AK_URL/api/v1/auth/me")" == 200 ]]
}
if token_ok; then
  log "existing $TOKEN_FILE still valid, reusing"
else
  tbody=$(jq -nc --arg n "ci-$(date -u +%Y%m%dT%H%M%SZ)" \
    '{name:$n,scopes:["read:artifacts","write:artifacts"],expires_in_days:30}')
  tok=$(api POST /users/me/tokens -d "$tbody" | jq -r .token)
  [[ -n "$tok" && "$tok" != null ]] || { echo "bootstrap.sh: token mint failed" >&2; exit 1; }
  (umask 077; printf '%s\n' "$tok" > "$TOKEN_FILE")
  log "minted CI token -> $TOKEN_FILE (user admin, 30 days)"
fi

# --- client config ----------------------------------------------------------------
mkdir -p "$OUT"
{
  echo "# Generated by registry/bootstrap.sh. All RPM repos served by Artifact Keeper."
  echo "# PoC only: gpgcheck=0. Replace @HOST@ (localhost | 10.0.2.2 | host.containers.internal)."
  for spec in "${REPOS[@]}"; do
    IFS='|' read -r key format rtype upstream name <<<"$spec"
    [[ "$format" == rpm ]] || continue
    printf '\n[%s]\nname=%s\nbaseurl=http://@HOST@:%s/rpm/%s\nenabled=1\ngpgcheck=0\nrepo_gpgcheck=0\nmetadata_expire=6h\n' \
      "$key" "$name" "$HTTP_PORT" "$key"
  done
} > "$OUT/edge.repo.in"
sed "/^baseurl=/s/@HOST@/$HOST/" "$OUT/edge.repo.in" > "$OUT/edge.repo"
log "wrote $OUT/edge.repo (HOST=$HOST) and $OUT/edge.repo.in"

cat > "$OUT/README-urls.md" <<MD
# Artifact Keeper endpoints (generated by bootstrap.sh)

Host used: \`$HOST\` (from a QEMU user-net VM use \`10.0.2.2\`; from a podman
container/build use \`host.containers.internal\`). Port: \`$HTTP_PORT\` (plain HTTP via Caddy).

| What | URL |
|---|---|
| Web UI | http://$HOST:$HTTP_PORT/ |
| API | http://$HOST:$HTTP_PORT/api/v1/ |
| Health | http://$HOST:$HTTP_PORT/livez, http://$HOST:$HTTP_PORT/readyz |
$(for spec in "${REPOS[@]}"; do IFS='|' read -r key format rtype upstream name <<<"$spec"
  if [[ $format == rpm ]]; then echo "| dnf baseurl \`$key\` ($rtype) | http://$HOST:$HTTP_PORT/rpm/$key |"
  else echo "| OCI \`$key\` ($rtype) | \`$HOST:$HTTP_PORT/$key/<image>:<tag>\` |"; fi; done)

Upload an RPM to \`rpm-edge-site\`:

    curl -u "admin:\$(cat registry/.ak-token)" -T foo.rpm http://$HOST:$HTTP_PORT/rpm/rpm-edge-site/packages/foo.rpm

Push a bootc image:

    podman login --tls-verify=false -u admin --password-stdin $HOST:$HTTP_PORT < registry/.ak-token
    podman push --tls-verify=false $HOST:$HTTP_PORT/oci-bootc/edge:latest

Pull through the quay.io proxy:

    podman pull --tls-verify=false $HOST:$HTTP_PORT/oci-quay-proxy/rockylinux/rockylinux:10
MD
log "wrote $OUT/README-urls.md"
log "done"
