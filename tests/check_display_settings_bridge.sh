#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

mkdir -p "$TMP_DIR/module/scripts" "$TMP_DIR/module/config" \
    "$TMP_DIR/module/bin" "$TMP_DIR/module/runtime" "$TMP_DIR/fakebin"
cp "$ROOT/scripts/display_settings_bridge.sh" "$TMP_DIR/module/scripts/"
touch "$TMP_DIR/module/bin/display_settings_bridge.dex"
cat > "$TMP_DIR/module/config/mode.txt" <<'EOF'
13
com.example.game=11
EOF

cat > "$TMP_DIR/fakebin/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in
    SurfaceFlinger)
        cat <<'MODES'
id=1, hwcId=1, resolution=1440x3136, vsyncRate=120.000000
id=4, hwcId=4, resolution=1080x2352, vsyncRate=144.000000
id=5, hwcId=5, resolution=1440x3136, vsyncRate=144.000000
id=7, hwcId=7, resolution=1440x3136, vsyncRate=165.000000
id=11, hwcId=11, resolution=1440x3136, vsyncRate=160.000000
id=13, hwcId=13, resolution=1440x3136, vsyncRate=170.000000
MODES
        ;;
    oplus_vrr_service) printf '%s\n' 'GlobalGameFilterMode: 1' ;;
esac
EOF
chmod +x "$TMP_DIR/fakebin/dumpsys"

cat > "$TMP_DIR/fakebin/settings" <<'EOF'
#!/bin/sh
key="$2:$3"
case "$1" in
    get)
        case "$key" in
            secure:oplus_customize_screen_refresh_rate) printf '%s\n' "${BRIDGE_SETTING_MODE:-7}" ;;
            global:user_preferred_resolution_width) printf '%s\n' "${BRIDGE_SETTING_WIDTH:-1440}" ;;
            global:user_preferred_resolution_height) printf '%s\n' "${BRIDGE_SETTING_HEIGHT:-3136}" ;;
            *) printf '%s\n' null ;;
        esac
        ;;
    put) printf '%s\n' "$2:$3=$4" >> "$BRIDGE_SETTINGS_LOG" ;;
esac
EOF
chmod +x "$TMP_DIR/fakebin/settings"

cat > "$TMP_DIR/fakebin/cmd" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$BRIDGE_CMD_LOG"
EOF
chmod +x "$TMP_DIR/fakebin/cmd"

cat > "$TMP_DIR/fakebin/app_process" <<'EOF'
#!/bin/sh
case "$3" in
    dump) printf 'com.example.game=%s\n' "${BRIDGE_APP_MODE:-4}" ;;
    get) printf '%s\n' "$4=7" ;;
    set) printf '%s\n' "$*" >> "$BRIDGE_APP_LOG" ;;
esac
EOF
chmod +x "$TMP_DIR/fakebin/app_process"

run_bridge() {
    PATH="$TMP_DIR/fakebin:$PATH" \
    DISPLAY_BRIDGE_APP_PROCESS="$TMP_DIR/fakebin/app_process" \
    BRIDGE_SETTINGS_LOG="$TMP_DIR/settings.log" \
    BRIDGE_CMD_LOG="$TMP_DIR/cmd.log" \
    BRIDGE_APP_LOG="$TMP_DIR/app.log" \
    BRIDGE_APP_MODE="${BRIDGE_APP_MODE:-4}" \
    sh "$TMP_DIR/module/scripts/display_settings_bridge.sh" "$@"
}

run_bridge sync-global
grep -q 'secure:oplus_customize_screen_refresh_rate=7' "$TMP_DIR/settings.log"
grep -q 'global:user_preferred_refresh_rate=170' "$TMP_DIR/settings.log"
grep -q 'system:min_refresh_rate=170' "$TMP_DIR/settings.log"
grep -q 'secure:user_preferred_screen_index=3' "$TMP_DIR/settings.log"
[ "$(tail -n 1 "$TMP_DIR/settings.log")" = 'system:min_refresh_rate=170' ]
grep -q 'sleep 1' "$ROOT/scripts/display_settings_bridge.sh"
[ ! -s "$TMP_DIR/cmd.log" ]

run_bridge sync-app com.example.game 11
grep -q 'authoritative:app=com.example.game,mode_id=11,fps=160,settings_ui=daemon' \
    "$TMP_DIR/module/runtime/display_settings_bridge/runtime.log"

BRIDGE_SETTING_MODE=7 BRIDGE_APP_MODE=7 run_bridge pull-once
[ "$(sed -n '1p' "$TMP_DIR/module/config/mode.txt")" = 13 ]
grep -q '^com.example.game=11$' "$TMP_DIR/module/config/mode.txt"

BRIDGE_SETTING_MODE=4 run_bridge pull-once
[ "$(sed -n '1p' "$TMP_DIR/module/config/mode.txt")" = 13 ]
grep -q '^com.example.game=11$' "$TMP_DIR/module/config/mode.txt"

grep -q 'OplusDisplayModeManager' "$ROOT/src/settings_bridge/DisplaySettingsBridge.java"
grep -q 'getAppOverrideRefreshRateList' "$ROOT/src/settings_bridge/DisplaySettingsBridge.java"
grep -q 'setAppOverrideRefreshRate' "$ROOT/src/settings_bridge/DisplaySettingsBridge.java"
grep -q 'GlobalGameFilterMode' "$ROOT/scripts/display_settings_bridge.sh"
grep -q 'SIGUSR1' "$ROOT/src/rate_daemon.c"
if grep -q 'cmd display set-user-preferred-display-mode' "$ROOT/scripts/display_settings_bridge.sh"; then
    echo 'FAIL: settings bridge still bypasses daemon ladder' >&2
    exit 1
fi

SET_CONFIG_BODY=$(sed -n '/"set_config")/,/;;/p' "$ROOT/scripts/web_handler.sh")
if printf '%s\n' "$SET_CONFIG_BODY" | grep -q 'SETTINGS_BRIDGE_HELPER.*sync-global'; then
    echo 'FAIL: WebUI set_config eagerly races the daemon with sync-global' >&2
    exit 1
fi

grep -q 'begin_coloros_resolution_change "$NEW_MODE" "$NEW_SPEC"' \
    "$ROOT/scripts/web_handler.sh"
grep -q 'ADOPTRES.*TARGET_MODE_ID.*RESOLUTION_GENERATION' \
    "$ROOT/scripts/web_handler.sh"
grep -q 'wm density "$TARGET_DENSITY"' "$ROOT/scripts/web_handler.sh"
grep -q "resolutionChange ? 'set_resolution_config' : 'set_config'" \
    "$ROOT/webroot/js/main.js"

echo 'PASS: display settings bridge synchronizes Web, Settings app overrides, and Game Assistant reapply signals'
