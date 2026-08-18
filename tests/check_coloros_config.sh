#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FREE="${1:-$ROOT/scripts/coloros_config.sh}"
PREMIUM="${2:-$ROOT/packaging/paid-payload/scripts/coloros_config_premium.sh}"
PYTHON="${PYTHON:-python3}"

[ -f "$FREE" ] || { echo "FAIL: missing free ColorOS config helper" >&2; exit 1; }
[ -f "$PREMIUM" ] || { echo "FAIL: missing premium ColorOS config helper" >&2; exit 1; }
sh -n "$FREE"
sh -n "$PREMIUM"

[ -f "$ROOT/config/coloros/oplus_vrr_config.json" ] || exit 1
[ -f "$ROOT/config/coloros/refresh_rate_config.xml" ] || exit 1
[ -f "$ROOT/config/coloros/multimedia_pixelworks_apps.xml" ] || exit 1

# Free VRR + refresh-rate sources stay parseable and correct.
"$PYTHON" - "$ROOT/config/coloros/oplus_vrr_config.json" \
    "$ROOT/config/coloros/refresh_rate_config.xml" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

vrr_path, rate_path = sys.argv[1:]
with open(vrr_path, encoding="utf-8") as stream:
    rows = json.load(stream)
merged = {}
for row in rows:
    if isinstance(row, dict):
        merged.update(row)

expected_sf = {"120", "90", "60", "30", "10", "1"}
expected_frtc = {"120", "90", "60", "30"}
assert str(merged.get("feature_sa")).lower() == "true"
assert merged.get("adfr_enable") is True
assert set(merged.get("sf_framerate_ranges", [])) == expected_sf
assert set(merged.get("frtc_framerate_ranges", [])) == expected_frtc

root = ET.parse(rate_path).getroot()
assert root.tag == "refresh_rate_config"
assert int(root.attrib["version"]) == 20260225
config = root.find("config")
assert config is not None
assert config.attrib.get("maxrefreshsettings") == "3"
assert "defaultMaxRate" not in config.attrib
assert "extremeHighEnable" not in config.attrib
PY

# MEMC base configuration stays a valid XML filter-conf for the premium half.
"$PYTHON" - "$ROOT/config/coloros/multimedia_pixelworks_apps.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

memc_path = sys.argv[1]
root = ET.parse(memc_path).getroot()
assert root.tag == "filter-conf"
packages = root.findall("mConfigPackage")
activities = root.findall("mConfigActivity")
assert packages and activities
assert {entry.attrib["rate"] for entry in packages} <= {"60", "120"}
assert {entry.attrib["type"] for entry in activities} <= {"258-10-0-0", "258-74-0-0"}
assert any(entry.text == "tv.danmaku.bili/com.bilibili.video.story.StoryVideoActivity"
           for entry in activities)
PY

# Free script: VRR + refresh-rate only. Must never fail over missing MEMC files.
grep -q '/my_product/etc/oplus_vrr_config.json' "$FREE"
grep -q '/my_product/etc/refresh_rate_config.xml' "$FREE"
grep -q 'mount --bind' "$FREE"
grep -q 'cmp -s' "$FREE"
grep -q 'RMX5200|PLK110|PJD110' "$FREE"
if grep -q 'VRR_BASELINE\|RATE_BASELINE\|target_not_stock' "$FREE"; then
    echo "FAIL: ColorOS config still requires stock output hashes" >&2
    exit 1
fi
# The free path must not reference the premium MEMC overlay anymore.
if grep -q '/my_product/vendor/etc/multimedia_pixelworks_apps.xml\|build_memc_source\|video_memc_apps.txt' "$FREE"; then
    echo "FAIL: free ColorOS config still carries the MEMC overlay" >&2
    exit 1
fi

# Premium script: MEMC overlay logic moved here, self-contained.
grep -q '/my_product/vendor/etc/multimedia_pixelworks_apps.xml' "$PREMIUM"
grep -q 'build_memc_source' "$PREMIUM"
grep -q 'remember_activity_alias' "$PREMIUM"
grep -q 'video_memc_apps.txt' "$PREMIUM"
grep -q 'mount --bind' "$PREMIUM"
grep -q 'cmp -s' "$PREMIUM"
grep -q 'apply-premium' "$PREMIUM"
grep -q '\[ "$RATE" -ge 30 \]' "$PREMIUM"
grep -q '\[ "$RATE" -le 1000 \]' "$PREMIUM"
if grep -q 'case "$RATE" in 60|120' "$PREMIUM"; then
    echo "FAIL: premium MEMC overlay still rejects valid display modes outside 60/120" >&2
    exit 1
fi

echo "PASS: ColorOS config is split - free VRR/rate path and premium MEMC path"
