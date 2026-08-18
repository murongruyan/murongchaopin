#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FILE="$ROOT/system/odm/etc/iris_page_i7p.json"
STOCK="$ROOT/config/iris_page_i7p.stock.sha256"

[ -f "$FILE" ]
[ -f "$STOCK" ]

# Keep this experiment limited to the service whitelist. The rest of the
# Iris capability document must remain equivalent to stock.
grep -Fq '"platform": "iris7p"' "$FILE"
grep -Fq '"scs_panel_fps"' "$FILE"
grep -Fq '"d0": [60, 90, 120, 144]' "$FILE"
if grep -Eq '"d0": \[[^]]*(150|165|170|175|180)' "$FILE"; then
    echo 'FAIL: overlay widened the Pixelworks whitelist beyond the 144Hz experiment' >&2
    exit 1
fi

python3 - "$FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
assert value["header"]["platform"] == "iris7p"
assert value["scs_panel_fps"]["d0"] == [60, 90, 120, 144]
PY

echo 'PASS: iris7p service whitelist overlay is limited to 144Hz'
