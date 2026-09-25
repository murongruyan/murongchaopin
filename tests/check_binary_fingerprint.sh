#!/bin/sh
# Checked-in build products that come from a source file in this repository:
#   <binary>|<source>|<version macro or ->|  plus the .src.sha256 sidecar the
# build writes next to each one.
#
# Both entries here were stale at some point.  bin/rate_daemon was 2026-09-18
# against a 2026-09-25 source, so a package assembled without recompiling would
# have shipped a daemon without the SurfaceFlinger OTI durability work.  And
# bin/ko_abi_guard was missing from the module ZIP entirely, which is how the
# RMX5200 DRM module ended up in the kernel's version check with no contract to
# adapt it to.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

ENTRIES="bin/rate_daemon|src/rate_daemon.c|RATE_DAEMON_VERSION
bin/ko_abi_guard|src/ko_abi_guard.c|-"

failed=0
# A plain for-loop over the word-split entries: a `printf | while read` pipeline
# would run in a subshell and lose every failure it recorded.
for entry in $ENTRIES; do
    binary=${entry%%|*}
    rest=${entry#*|}
    source=${rest%%|*}
    macro=${rest#*|}
    [ -n "$binary" ] || continue
    if [ ! -f "$binary" ]; then
        echo "FAIL: $binary is missing" >&2
        failed=1
        continue
    fi
    if [ ! -f "$binary.src.sha256" ]; then
        echo "FAIL: $binary.src.sha256 is missing; rebuild $binary" >&2
        failed=1
        continue
    fi
    recorded=$(cut -d' ' -f1 < "$binary.src.sha256")
    actual=$(sha256sum "$source" | cut -d' ' -f1)
    if [ "$recorded" != "$actual" ]; then
        echo "FAIL: $binary was built from an older $source; rebuild it" >&2
        failed=1
        continue
    fi
    if [ "$macro" != "-" ]; then
        version=$(sed -n "s/^#define $macro \"\([^\"]*\)\"/\1/p" "$source")
        if [ -z "$version" ]; then
            echo "FAIL: no $macro in $source" >&2
            failed=1
            continue
        fi
        if ! strings "$binary" | grep -qx "$version"; then
            echo "FAIL: $binary does not carry $version" >&2
            failed=1
            continue
        fi
        echo "ok   $binary ($version)"
    else
        echo "ok   $binary"
    fi
done

[ "$failed" -eq 0 ] || exit 1

echo 'build product fingerprints match their sources: OK'
