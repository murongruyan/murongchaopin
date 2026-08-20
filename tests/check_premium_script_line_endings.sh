#!/bin/sh
set -eu

# Android's shell treats CR as part of a token. Paid boot scripts must remain
# LF-only because they are delivered through a cross-platform package flow.
bad=0
for script in packaging/paid-payload/scripts/*.sh; do
    [ -f "$script" ] || continue
    if LC_ALL=C grep -q "$(printf '\r')" "$script"; then
        echo "FAIL: CRLF line ending in $script" >&2
        bad=$((bad + 1))
    fi
done

[ "$bad" -eq 0 ] || exit 1
echo 'PASS: paid shell payloads are LF-only'
