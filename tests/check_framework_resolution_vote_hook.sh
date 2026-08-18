#!/system/bin/sh
set -eu

root_dir="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
hook="$root_dir/src/settings_hook/java/com/murongchaopin/displayhook/FrameworkResolutionVoteHooks.java"
services="$root_dir/src/settings_hook/java/com/murongchaopin/displayhook/OplusServicesHooks.java"

test -f "$hook"
grep -q '"PRIORITY_APP_REQUEST_SIZE"' "$hook"
grep -q '"PRIORITY_USER_SETTING_DISPLAY_PREFERRED_SIZE"' "$hook"
grep -q 'alignAppSizeVote' "$hook"
grep -q 'forcePreferredGeometry' "$hook"
grep -q '"adjustSize"' "$hook"
grep -q '"filterModes"' "$hook"
grep -q 'CALCULATION_GEOMETRY' "$hook"
grep -q 'RMX5200' "$hook"
grep -q 'FrameworkResolutionVoteHooks.install' "$services"

echo "framework resolution vote hook: OK"
