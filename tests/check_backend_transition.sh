#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

mkdir -p "$TMP_DIR/scripts" "$TMP_DIR/config" "$TMP_DIR/img" "$TMP_DIR/bin" "$TMP_DIR/fakebin" "$TMP_DIR/state"
cp "$ROOT/scripts/web_handler.sh" "$TMP_DIR/web_handler.sh"

printf '%s\n' dtbo > "$TMP_DIR/config/dts_backend.txt"
printf '%s\n' stock-dtbo > "$TMP_DIR/img/dtbo.img"

cat > "$TMP_DIR/scripts/dtbo_avb.sh" <<EOF
dtbo_validate_stock_backup() { return 0; }
dtbo_validate_stock_recovery() { return 0; }
dtbo_write_stock_recovery() { return 0; }
dtbo_recover_stock_backup() { return 1; }
dtbo_hash_file() { sha256sum "\$1" | awk '{print \$1}'; }
dtbo_hash_device_prefix() {
    if [ -f "$TMP_DIR/state/restored" ]; then
        dtbo_hash_file "$TMP_DIR/img/dtbo.img"
    else
        printf '%s\n' partition-is-different
    fi
}
dtbo_write_partition() {
    printf '%s %s\n' "\$1" "\$2" >> "$TMP_DIR/state/writes"
    touch "$TMP_DIR/state/restored"
    return 0
}
EOF

cat > "$TMP_DIR/scripts/hmbird_backend.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP_DIR/state/hmbird.calls"
printf '%s\n' 'Success: HMBIRD-only DTBO applied'
EOF
chmod +x "$TMP_DIR/scripts/hmbird_backend.sh"

cat > "$TMP_DIR/fakebin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
    ro.product.vendor.model) printf '%s\n' RMX5200 ;;
    ro.boot.slot_suffix) printf '%s\n' _a ;;
esac
EOF
chmod +x "$TMP_DIR/fakebin/getprop"

run_handler() {
    PATH="$TMP_DIR/fakebin:$PATH" \
    MURONGCHAOPIN_MOD_PATH="$TMP_DIR" \
        sh "$TMP_DIR/web_handler.sh" "$@"
}

run_handler set_dts_backend drm | grep -q '^Success:'
[ "$(sed -n '1p' "$TMP_DIR/config/dts_backend.txt")" = drm ]
[ ! -e "$TMP_DIR/state/hmbird.calls" ]
[ ! -e "$TMP_DIR/state/writes" ]

# Selecting a segmented control must stay instant. The HMBIRD-only DTBO is
# generated only after the user presses Apply.
grep -A12 '^do_apply_selected_backend()' "$ROOT/scripts/web_handler.sh" |
    grep -q 'prepare_backend_transition drm'

# A loaded KO is intentionally left for the reboot boundary; no online rmmod
# is attempted.
run_handler set_dts_backend dtbo | grep -q '^Success:'
[ "$(sed -n '1p' "$TMP_DIR/config/dts_backend.txt")" = dtbo ]
[ ! -e "$TMP_DIR/state/hmbird.calls" ]
grep -q 'drm_remove_requires_reboot' "$ROOT/scripts/display_backend.sh"
if grep -qE '(^|[[:space:]])rmmod([[:space:]]|$)' "$ROOT/scripts/display_backend.sh"; then
    echo "FAIL: backend helper offers online rmmod" >&2
    exit 1
fi

echo "PASS: backend selection is non-blocking and DRM apply owns the HMBIRD-only DTBO transition"
