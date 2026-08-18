#!/bin/sh
set -eu

HELPER=scripts/libsdmclient_timeline_patch.sh
PAYLOAD=bin/libsdmclient.rmx5200.ltpo-timeline.so

grep -q 'EXPECTED_MODEL=RMX5200' "$HELPER"
grep -q 'EXPECTED_SOURCE_SHA=714493f26a1ec67eba2887fa0dbd6c8a0d0a12449f05f4fcd6967c0854b736a6' "$HELPER"
grep -q 'EXPECTED_PATCHED_SHA=21eaefdb1f1576a21f45d52bba295af2ab65f38a302375a493afd6fa3a6ee0aa' "$HELPER"
grep -q 'TOKEN_VALUE=I_UNDERSTAND_RMX5200_LTPO_TIMELINE_COMBINED_TEST_ONCE' "$HELPER"
grep -q 'CAVE_OFFSET=411264' "$HELPER"
grep -q 'INITIAL_TIMELINE_OFFSET=705364' "$HELPER"
grep -q 'INITIAL_TIMELINE_ORIGINAL_HEX=81ca01f9' "$HELPER"
grep -q 'INITIAL_TIMELINE_PATCHED_HEX=cbe0fe17' "$HELPER"
grep -q 'TIMELINE_OFFSET=732648' "$HELPER"
grep -q 'TIMELINE_ORIGINAL_HEX=7cd641f9' "$HELPER"
grep -q 'TIMELINE_PATCHED_HEX=32c6fe17' "$HELPER"
grep -q 'fallback:previous_boot_incomplete' "$HELPER"
grep -q 'skipped:no_one_shot_token' "$HELPER"
grep -q 'mount --bind "$PATCHED_FILE" "$SOURCE_FILE"' "$HELPER"
grep -q 'umount -l "$SOURCE_FILE"' "$HELPER"
if grep -q 'libsdmclient_timeline_patch.sh' \
        post-fs-data.sh service.sh scripts/web_handler.sh uninstall.sh \
        packaging/paid-payload/scripts/*.sh; then
    echo 'FAIL: research SDM timeline experiment is wired into a release path' >&2
    exit 1
fi

[ "$(wc -c < "$PAYLOAD" | tr -d '[:space:]')" = 1108824 ]
[ "$(sha256sum "$PAYLOAD" | awk '{print $1}')" = \
  21eaefdb1f1576a21f45d52bba295af2ab65f38a302375a493afd6fa3a6ee0aa ]
[ "$(od -An -v -tx1 -j 411264 -N 84 "$PAYLOAD" | tr -d '[:space:]')" = \
  e80b40b9094099524973a7721f01096b6100005453000035e10300aa81ca01f92e1f0114000000000000000000000000094099524973a7721f03096b81000054684244b948000035e10300aa7cd641f9c7390114 ]
[ "$(od -An -v -tx1 -j 705364 -N 4 "$PAYLOAD" | tr -d '[:space:]')" = \
  cbe0fe17 ]
[ "$(od -An -v -tx1 -j 732648 -N 4 "$PAYLOAD" | tr -d '[:space:]')" = \
  32c6fe17 ]

echo 'PASS: RMX5200 SDM timeline experiment is pinned but detached from releases'
