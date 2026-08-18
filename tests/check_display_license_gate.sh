#!/system/bin/sh
# check_display_license_gate.sh - on-device authorization gate test.
# Expects a prepared tree at /data/local/tmp/gatetest (see
# tools/test_display_gate.ps1 which builds fixtures and pushes them).
set -u

TEST_ROOT=$(dirname $(dirname "$0"))
export MURONGCHAOPIN_MOD_PATH="$TEST_ROOT/mod"
GATE="$MURONGCHAOPIN_MOD_PATH/scripts/display_license_gate.sh"
WEB_HANDLER="$MURONGCHAOPIN_MOD_PATH/scripts/web_handler.sh"
[ -f "$GATE" ] || { echo "gate script missing"; exit 1; }
. "$GATE"

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 ($2)"; failures=$((failures + 1)); }

expect_mode() {
    # $1 label, $2 lease file, $3 expected mode
    cp "$TEST_ROOT/cases/$2" "$GATE_LEASE_FILE" 2>/dev/null
    chmod 600 "$GATE_LEASE_FILE" 2>/dev/null
    gate_lease_verify
    if [ "$GATE_LEASE_MODE" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "mode=$GATE_LEASE_MODE expected=$3 reason=$GATE_LEASE_REASON"
    fi
}

expect_check() {
    # $1 label, $2 feature, $3 expected exit code
    gate_check "$2"
    rc=$?
    if [ "$rc" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "rc=$rc expected=$3 reason=$GATE_REASON"
    fi
}

echo "== device id =="
DEVICE_INFO_OUTPUT=$(gate_device_info_print)
printf '%s\n' "$DEVICE_INFO_OUTPUT" | sed -n '1,6p'
for FIELD in device_id sn imei1 imei2; do
    if printf '%s\n' "$DEVICE_INFO_OUTPUT" | grep -q "^${FIELD}="; then
        pass "raw device field ${FIELD} is exported"
    else
        fail "raw device field ${FIELD} is exported" "missing ${FIELD}"
    fi
done
HASH=$(gate_device_id_hash)
if printf '%s' "$HASH" | grep -Eq '^[0-9a-f]{64}$'; then
    pass "device_id_hash looks like 64 hex"
else
    fail "device_id_hash" "got '$HASH'"
fi

ARRAY_CASE=$(mktemp)
printf '%s\n' '{"supported_backends":["drm","dtbo"]}' > "$ARRAY_CASE"
if gate_list_contains "$ARRAY_CASE" supported_backends dtbo; then
    pass "multi-entry backend array is parsed"
else
    fail "multi-entry backend array is parsed" "dtbo entry was not found"
fi
rm -f "$ARRAY_CASE"

echo "== lease verification =="
rm -f "$GATE_LEASE_FILE"
gate_lease_verify
[ "$GATE_LEASE_MODE" = "missing" ] && pass "missing lease detected" || fail "missing lease detected" "mode=$GATE_LEASE_MODE"
expect_mode "valid lease" lease-valid.json valid
expect_mode "grace lease" lease-grace.json grace
expect_mode "expired lease" lease-expired.json expired
expect_mode "tampered signature" lease-tampered.json invalid
expect_mode "wrong device" lease-wrong-device.json invalid

echo "== feature checks =="
cp "$TEST_ROOT/cases/lease-valid.json" "$GATE_LEASE_FILE"
chmod 600 "$GATE_LEASE_FILE"
expect_check "video_memc allowed" video_memc 0
expect_check "adfr_disable allowed" adfr_disable 0
expect_check "custom_ltpo allowed" custom_ltpo 0
cp "$TEST_ROOT/cases/lease-noltpo.json" "$GATE_LEASE_FILE"
chmod 600 "$GATE_LEASE_FILE"
expect_check "custom_ltpo not covered" custom_ltpo 1
expect_check "video_memc covered" video_memc 0
cp "$TEST_ROOT/cases/lease-grace.json" "$GATE_LEASE_FILE"
chmod 600 "$GATE_LEASE_FILE"
expect_check "grace allows feature" video_memc 2

echo "== lease save flow =="
LEASE_B64=$(cat "$TEST_ROOT/cases/lease-valid.b64")
OUT=$(gate_lease_save "$LEASE_B64")
case "$OUT" in
    Success*) pass "lease save ($OUT)" ;;
    *) fail "lease save" "$OUT" ;;
esac

echo "== account save/clear =="
gate_account_save "tester" "42" "tok_secret_value"
grep -q '"username":"tester"' "$GATE_ACCOUNT_FILE" && pass "account saved" || fail "account saved" "file missing"
if gate_state_print | grep -q "tok_secret_value"; then
    fail "account token leak" "token appeared in state output"
else
    pass "account token not leaked"
fi
gate_account_clear
[ -f "$GATE_ACCOUNT_FILE" ] && fail "account clear" "file still exists" || pass "account clear"

echo "== web_handler premium gating =="
cp "$TEST_ROOT/cases/lease-valid.json" "$GATE_LEASE_FILE"
chmod 600 "$GATE_LEASE_FILE"
OUT=$(sh "$WEB_HANDLER" get_video_motion_config 2>&1)
case "$OUT" in
    *"target="*) pass "web premium read allowed with lease" ;;
    *) fail "web premium read allowed with lease" "$OUT" ;;
esac
rm -f "$GATE_LEASE_FILE"
OUT=$(sh "$WEB_HANDLER" get_video_motion_config 2>&1)
rc=$?
case "$OUT" in
    *"requires authorization"*) [ "$rc" -ne 0 ] && pass "web premium read denied without lease" || fail "web premium read denied without lease" "rc=$rc" ;;
    *) fail "web premium read denied without lease" "$OUT" ;;
esac
OUT=$(sh "$WEB_HANDLER" set_video_motion_target 120 2>&1)
case "$OUT" in
    *"requires authorization"*) pass "web set target denied without lease" ;;
    *) fail "web set target denied without lease" "$OUT" ;;
esac
OUT=$(sh "$WEB_HANDLER" toggle_adfr disable 2>&1)
case "$OUT" in
    *"requires authorization"*) pass "web toggle_adfr disable denied without lease" ;;
    *) fail "web toggle_adfr disable denied without lease" "$OUT" ;;
esac
OUT=$(sh "$WEB_HANDLER" set_display_policy custom_ltpo 2>&1)
case "$OUT" in
    *"requires authorization"*) pass "web custom_ltpo policy denied without lease" ;;
    *) fail "web custom_ltpo policy denied without lease" "$OUT" ;;
esac

echo "== package install =="
gate_package_abort
SHA_OK=$(cat "$TEST_ROOT/cases/pkg-ok.sha256")
SHA_BAD=$(cat "$TEST_ROOT/cases/pkg-badfile.sha256")
SHA_SYM=$(cat "$TEST_ROOT/cases/pkg-symlink.sha256")
SHA_EXTRA=$(cat "$TEST_ROOT/cases/pkg-extra.sha256")

write_pkg() {
    _name="$1"
    _file="$2"
    _chunkdir="$TEST_ROOT/chunks/$_name"
    rm -rf "$_chunkdir"
    mkdir -p "$_chunkdir" || return 1
    split -a 3 -b 65536 "$_file" "$_chunkdir/part." || return 1
    for _part in "$_chunkdir"/part.*; do
        _suffix=${_part##*.}
        _idx=$(echo "$_suffix" | awk '{ s = $0; v = 0; n = split(s, a, ""); for (i = 1; i <= n; i++) { c = index("abcdefghijklmnopqrstuvwxyz", a[i]); v = v * 26 + (c - 1) } print v }')
        _offset=$((_idx * 65536))
        base64 "$_part" > "$_chunkdir/chunk.$_offset.b64" || return 1
    done
    rm -f "$GATE_DOWNLOAD_FILE" "$GATE_DOWNLOAD_META"
    _offset=0
    _total=$(wc -c < "$_file" | tr -d ' ')
    while [ "$_offset" -lt "$_total" ]; do
        _chunk="$TEST_ROOT/chunks/$_name/chunk.$_offset.b64"
        _b64=$(cat "$_chunk" 2>/dev/null)
        [ -n "$_b64" ] || break
        gate_package_write "$_offset" "$_b64" >/dev/null || return 1
        _offset=$(wc -c < "$GATE_DOWNLOAD_FILE" | tr -d ' ')
    done
    [ "$_offset" = "$_total" ]
}

cp "$TEST_ROOT/cases/lease-valid.json" "$GATE_LEASE_FILE"
chmod 600 "$GATE_LEASE_FILE"
write_pkg "pkg-ok.zip" "$TEST_ROOT/cases/pkg-ok.zip" || fail "chunk write ok" "chunking failed"
OUT=$(gate_package_commit "$SHA_OK" "9" "1.0.0")
case "$OUT" in
    Success*) pass "package commit ok ($OUT)" ;;
    *) fail "package commit ok" "$OUT" ;;
esac
[ -f "$GATE_PREMIUM_DIR/manifest.json" ] && pass "premium dir installed" || fail "premium dir installed" "missing"
[ -f "$GATE_PREMIUM_DIR/scripts/premium_test.sh" ] && pass "target_path file installed" || fail "target_path file installed" "missing"
[ ! -e "$GATE_PREMIUM_DIR/payload" ] && pass "transport payload prefix stripped" || fail "transport payload prefix stripped" "payload directory leaked into runtime tree"
[ -x "$GATE_PREMIUM_DIR/scripts/premium_test.sh" ] && pass "0755 target mode applied" || fail "0755 target mode applied" "script is not executable"
[ ! -x "$GATE_PREMIUM_DIR/hooks/premium.apk" ] && pass "0644 target mode applied" || fail "0644 target mode applied" "APK is executable"
VERSION=$(gate_json_field "$GATE_PACKAGE_FILE" version)
[ "$VERSION" = "1.0.0" ] && pass "package.json version" || fail "package.json version" "got $VERSION"
VERSION_CODE=$(gate_json_number "$GATE_PACKAGE_FILE" version_code)
[ "$VERSION_CODE" = "1" ] && pass "package.json version_code" || fail "package.json version_code" "got $VERSION_CODE"
PACKAGE_STATE=$(gate_state_print)
printf '%s\n' "$PACKAGE_STATE" | grep -q '^package_version_code=1$' && \
    pass "auth state exposes package version_code" || \
    fail "auth state exposes package version_code" "missing package_version_code=1"
[ "$(gate_json_field "$GATE_STATE_FILE" remove_premium)" = "0" ] && pass "package commit re-enables paid boot" || fail "package commit re-enables paid boot" "remove_premium not reset"
[ "$(gate_json_field "$GATE_STATE_FILE" reboot_required)" = "1" ] && pass "package commit requests one reboot" || fail "package commit requests one reboot" "marker missing"

echo "== server-authorized dtbo compatibility bridge =="
gate_package_abort
printf 'dtbo\n' > "$TEST_ROOT/mod/config/dts_backend.txt"
write_pkg "pkg-ok.zip" "$TEST_ROOT/cases/pkg-ok.zip" || fail "chunk write dtbo bridge" "chunking failed"
gate_backend_override_write "9" "$SHA_OK" dtbo || fail "write dtbo bridge" "override write failed"
OUT=$(gate_package_commit "$SHA_OK" "9" "1.0.0")
case "$OUT" in
    *"server-authorized DTBO compatibility bridge"*Success*) pass "dtbo bridge accepts signed drm manifest" ;;
    *) fail "dtbo bridge accepts signed drm manifest" "$OUT" ;;
esac
[ ! -f "$GATE_BACKEND_OVERRIDE_FILE" ] && pass "dtbo bridge is one-shot" || fail "dtbo bridge is one-shot" "override file remained"
printf 'drm\n' > "$TEST_ROOT/mod/config/dts_backend.txt"

OUT=$(gate_package_boot_complete)
case "$OUT" in
    Success*) pass "paid boot consumes reboot marker" ;;
    *) fail "paid boot consumes reboot marker" "$OUT" ;;
esac
[ "$(gate_json_field "$GATE_STATE_FILE" reboot_required)" = "0" ] && pass "reboot marker cleared" || fail "reboot marker cleared" "marker still set"

gate_package_abort
write_pkg "pkg-badfile.zip" "$TEST_ROOT/cases/pkg-badfile.zip" || fail "chunk write badfile" "chunking failed"
OUT=$(gate_package_commit "$SHA_BAD" "10" "1.0.0")
case "$OUT" in
    *"sha256 mismatch for"*) pass "package commit rejects tampered file" ;;
    *) fail "package commit rejects tampered file" "$OUT" ;;
esac

gate_package_abort
write_pkg "pkg-symlink.zip" "$TEST_ROOT/cases/pkg-symlink.zip" || fail "chunk write symlink" "chunking failed"
OUT=$(gate_package_commit "$SHA_SYM" "11" "1.0.0")
# toybox unzip materializes symlink entries as regular files; either way the
# package must be rejected (link refused or undeclared file refused).
case "$OUT" in
    *"symbolic links"*|*"undeclared file"*) pass "package commit rejects symlinks" ;;
    *) fail "package commit rejects symlinks" "$OUT" ;;
esac

gate_package_abort
write_pkg "pkg-extra.zip" "$TEST_ROOT/cases/pkg-extra.zip" || fail "chunk write extra" "chunking failed"
OUT=$(gate_package_commit "$SHA_EXTRA" "12" "1.0.0")
case "$OUT" in
    *"undeclared file"*) pass "package commit rejects undeclared files" ;;
    *) fail "package commit rejects undeclared files" "$OUT" ;;
esac

gate_package_abort
OUT=$(gate_package_commit "$(printf 'ab%.0s' 1 32)" "13" "1.0.0")
case "$OUT" in
    *"no staged download"*) pass "commit without download rejected" ;;
    *) fail "commit without download rejected" "$OUT" ;;
esac

echo "== package remove =="
OUT=$(gate_package_remove)
case "$OUT" in
    Success*) pass "package remove marks next boot" ;;
    *) fail "package remove" "$OUT" ;;
esac
[ "$(gate_json_field "$GATE_STATE_FILE" remove_premium)" = "1" ] && pass "remove_premium persisted" || fail "remove_premium persisted" "missing"

OUT=$(gate_entitlement_cache "revoked" "F2S9" "RMX5200")
case "$OUT" in
    Success*) pass "revoked entitlement schedules free boot" ;;
    *) fail "revoked entitlement schedules free boot" "$OUT" ;;
esac
[ "$(gate_json_field "$GATE_STATE_FILE" remove_premium)" = "1" ] && pass "revoked entitlement keeps removal marker" || fail "revoked entitlement keeps removal marker" "marker missing"

OUT=$(gate_lease_save "$LEASE_B64")
case "$OUT" in
    Success*) pass "fresh signed lease re-enables installed package" ;;
    *) fail "fresh signed lease re-enables installed package" "$OUT" ;;
esac
[ "$(gate_json_field "$GATE_STATE_FILE" remove_premium)" = "0" ] && pass "fresh lease clears removal marker" || fail "fresh lease clears removal marker" "marker still set"
[ "$(gate_json_field "$GATE_STATE_FILE" reboot_required)" = "1" ] && pass "re-enabled package requests reboot" || fail "re-enabled package requests reboot" "marker missing"

echo "== auth_state =="
if gate_state_print > "$TEST_ROOT/auth-state.out"; then
    pass "auth_state returns success for a normal unlicensed state"
else
    fail "auth_state return code" "normal state returned non-zero"
fi
sed -n '1,8p' "$TEST_ROOT/auth-state.out"

echo
if [ "$failures" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$failures FAILURE(S)"
    exit 1
fi
