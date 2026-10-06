#!/usr/bin/env bash
# Download Rocky pxeboot vmlinuz + initrd.img into deploy/cache/ and verify them
# against the sha256 sums in the tree's .treeinfo. Re-runs are no-ops when cached
# files still match.
source "$(dirname "$0")/lib.sh"

treeinfo="$CACHE_DIR/treeinfo"
curl -fsSL --retry 3 -o "$treeinfo.new" "$ROCKY_TREE/.treeinfo"
mv "$treeinfo.new" "$treeinfo"

for f in vmlinuz initrd.img; do
  want="$(awk -F' *= *' -v k="images/pxeboot/$f" '$1==k {sub(/^sha256:/,"",$2); print $2}' "$treeinfo")"
  [[ -n "$want" ]] || die "no sha256 for images/pxeboot/$f in $ROCKY_TREE/.treeinfo"
  dest="$CACHE_DIR/$f"
  if [[ -f "$dest" ]] && echo "$want  $dest" | sha256sum -c --status; then
    log "$f cached and verified"
    continue
  fi
  log "downloading $f"
  curl -fsSL --retry 3 -o "$dest.part" "$ROCKY_TREE/images/pxeboot/$f"
  echo "$want  $dest.part" | sha256sum -c --status || die "$f checksum mismatch"
  mv "$dest.part" "$dest"
  log "$f verified sha256:$want"
done
