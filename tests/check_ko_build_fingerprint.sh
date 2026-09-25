#!/bin/sh
# A checked-in kernel module is only as good as the source it was built from.
# Rebuilding is the release path, but a local build can skip it (-SkipKoBuild)
# and then ship whatever binary happens to sit in bin/.  That is how the
# ColorOS 17 layout fix ended up committed in src/ko while bin/ still held the
# pre-fix modules.  Every rebuilt module writes a .src.sha256 sidecar naming the
# exact src/ko inputs it came from; this refuses to let those drift apart.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

EXEMPT="src/ko/fingerprint-exempt.txt"
failed=0

for module in bin/*.ko; do
    [ -f "$module" ] || continue
    name=$(basename "$module")
    fingerprint="$module.src.sha256"
    if [ -f "$fingerprint" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            recorded=${line%%  *}
            input=${line#*  }
            if [ ! -f "src/ko/$input" ]; then
                echo "FAIL: $name records a missing input src/ko/$input" >&2
                failed=1
                continue
            fi
            actual=$(sha256sum "src/ko/$input" | cut -d' ' -f1)
            if [ "$recorded" != "$actual" ]; then
                echo "FAIL: $name was built from an older src/ko/$input; rebuild it" >&2
                failed=1
            fi
        done < "$fingerprint"
        continue
    fi
    if [ -f "$EXEMPT" ] && grep -qx "$name" "$EXEMPT"; then
        continue
    fi
    echo "FAIL: $name has no $fingerprint and is not listed in $EXEMPT" >&2
    failed=1
done

[ "$failed" -eq 0 ] || exit 1
echo 'kernel module build fingerprints match their sources: OK'