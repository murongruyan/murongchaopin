#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/config" "$TMP_DIR/scripts" "$TMP_DIR/runtime" "$TMP_DIR/fakebin"
cp "$ROOT/scripts/web_handler.sh" "$TMP_DIR/web_handler.sh"
cp "$ROOT/scripts/mode_manifest.sh" "$TMP_DIR/scripts/mode_manifest.sh"
cp "$ROOT/config/display_mode_manifest.txt" "$TMP_DIR/config/display_mode_manifest.txt"
printf '%s\n' drm > "$TMP_DIR/config/dts_backend.txt"

cat > "$TMP_DIR/fakebin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
    ro.product.vendor.model) printf '%s\n' RMX5200 ;;
esac
EOF
cat > "$TMP_DIR/bin/process_dts" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${PROCESS_DTS_CALLS:?}"
EOF
chmod +x "$TMP_DIR/fakebin/getprop" "$TMP_DIR/bin/process_dts"

run_handler() {
    PATH="$TMP_DIR/fakebin:$PATH" \
    PROCESS_DTS_CALLS="$TMP_DIR/process_dts.calls" \
    MURONGCHAOPIN_MOD_PATH="$TMP_DIR" \
        sh "$TMP_DIR/web_handler.sh" "$@"
}

: > "$TMP_DIR/process_dts.calls"
SCAN=$(run_handler scan_rates)
printf '%s\n' "$SCAN" | grep -q '"fps":123'
printf '%s\n' "$SCAN" | grep -q '"width":1440,"height":3136'

run_handler add_rate 144 187 1880000000 5000 >/dev/null
grep -q '1440x3136@187:1880000000:5000:144' "$TMP_DIR/runtime/drm_modes.txt"
SCAN=$(run_handler scan_rates)
printf '%s\n' "$SCAN" | grep -q '"fps":187,"clock":1880000000,"transfer":5000,"base":144'

# Saving the same target updates its parameters instead of appending a second
# ambiguous mode specification.
run_handler add_rate 120 187 1770000000 6000 >/dev/null
grep -q '1440x3136@187:1770000000:6000:120' "$TMP_DIR/runtime/drm_modes.txt"
[ "$(tr ';' '\n' < "$TMP_DIR/runtime/drm_modes.txt" | grep -c '@187')" = 1 ]
: > "$TMP_DIR/process_dts.calls"
run_handler auto_process >/dev/null
[ ! -s "$TMP_DIR/process_dts.calls" ]

run_handler remove_rate runtime@187 >/dev/null
if grep -q '1440x3136@187' "$TMP_DIR/runtime/drm_modes.txt"; then
    echo "FAIL: DRM remove_rate left the custom mode" >&2
    exit 1
fi

echo "PASS: DRM Web scan/add/remove uses runtime mode_specs and never invokes process_dts"
