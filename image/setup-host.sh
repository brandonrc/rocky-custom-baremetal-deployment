#!/usr/bin/env bash
# Mark the local Artifact Keeper (plain HTTP on localhost:30080) as an insecure
# registry for this user's podman/skopeo/buildah, so FROM/pull/push work without
# --tls-verify=false. User-level drop-in: no sudo needed. Idempotent.
set -euo pipefail
AK="${AK:-localhost:30080}"
dir="${XDG_CONFIG_HOME:-$HOME/.config}/containers/registries.conf.d"
f="$dir/50-artifact-keeper-local.conf"
mkdir -p "$dir"
want="# Artifact Keeper on this workstation serves plain HTTP on :30080.
# Installed by rocky-custom-baremetal-deployment image/setup-host.sh
[[registry]]
location = \"$AK\"
insecure = true"
if [[ -f "$f" && "$(cat "$f")" == "$want" ]]; then
  echo "setup-host: $f already in place"
else
  printf '%s\n' "$want" > "$f"
  echo "setup-host: wrote $f"
fi
