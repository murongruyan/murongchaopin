#!/bin/sh
# The free daemon is a checked-in build product.  It was 2026-09-18 while
# src/rate_daemon.c was 2026-09-25, so a module assembled without recompiling
# shipped a daemon that was missing the SurfaceFlinger OTI durability work --
# the same "binary outlives its source" failure that hit the kernel modules.
# build_daemon.bat writes a .src.sha256 next to the binary; this refuses to let
# the two drift apart.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

BINARY=bin/rate_daemon
SOURCE=src/rate_daemon.c
FINGERPRINT="$BINARY.src.sha256"

if [ ! -f "$BINARY" ]; then
    echo "FAIL: $BINARY is missing" >&2
    exit 1
fi
if [ ! -f "$FINGERPRINT" ]; then
    echo "FAIL: $FINGERPRINT is missing; rebuild the daemon with build_daemon.bat" >&2
    exit 1
fi

recorded=$(cut -d' ' -f1 < "$FINGERPRINT")
actual=$(sha256sum "$SOURCE" | cut -d' ' -f1)
if [ "$recorded" != "$actual" ]; then
    echo "FAIL: $BINARY was built from an older $SOURCE; rebuild it" >&2
    exit 1
fi

# The version banner the daemon prints must agree with the source, which is what
# the release pipeline asserts against module.prop.
version=$(sed -n 's/^#define RATE_DAEMON_VERSION "\([^"]*\)"/\1/p' "$SOURCE")
[ -n "$version" ] || { echo "FAIL: no RATE_DAEMON_VERSION in $SOURCE" >&2; exit 1; }
if ! strings "$BINARY" | grep -qx "$version"; then
    echo "FAIL: $BINARY does not carry $version" >&2
    exit 1
fi

echo "rate daemon build fingerprint matches its source: OK ($version)"