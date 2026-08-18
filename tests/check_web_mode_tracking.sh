#!/system/bin/sh

set -eu

ROOT=${1:-.}
JS="$ROOT/webroot/js/main.js"

grep -q 'let appliedMode = -1;' "$JS"
grep -q 'startAppliedModePolling();' "$JS"
grep -q 'head -n 1.*CONFIG_FILE' "$JS"
grep -q 'mode.id === appliedMode' "$JS"
grep -q 'selectionFollowedApplied' "$JS"

echo 'PASS: WebUI tracks the applied display mode without overwriting an unsaved selection'
