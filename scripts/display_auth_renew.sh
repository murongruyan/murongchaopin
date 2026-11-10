#!/system/bin/sh
# display_auth_renew.sh - headless renewal of the login token and paid display lease.
#
# Why: the WebUI used to be the only place that renewed credentials, so a user
# who never opened it silently lost the 7-day login token and the 3-day lease
# (grace 10 days), then had to log in again. This helper runs from the boot
# service, renews on a 6h schedule and keeps the existing credentials whenever
# the network or the server is unavailable.
#
# It never talks to the backend directly: every network/credential write goes
# through web_handler.sh (api_request / auth_update_token / auth_save_lease),
# which already implements the HTTPS channel, the X-Refresh-Token capture and
# the verified, atomic, 0600 lease save.
#
# Usage:
#   display_auth_renew.sh --loop        # boot service entry (single instance)
#   display_auth_renew.sh --once        # one check, exit 0 ok / 1 failed / 2 not logged in
#   display_auth_renew.sh --once --force# one check, renew the lease even when not due
#   display_auth_renew.sh --status      # print local credential state (no network)
#
# Environment overrides (testing/support; defaults are production values):
#   MURONG_AUTH_RENEW_MODDIR        module dir (default: parent of this script)
#   MURONG_AUTH_RENEW_LEASE_WINDOW  renew when lease expires within N seconds (86400)
#   MURONG_AUTH_RENEW_INTERVAL      loop period seconds (21600 = 6h)
#   MURONG_AUTH_RENEW_RETRY         retry delay after a failure (1800 = 30m)
#   MURONG_AUTH_RENEW_MAX_FAIL      consecutive retries before falling back to the period (3)
#   MURONG_AUTH_RENEW_BOOT_DELAY    first-run delay after boot (90s, network settle)
#   MURONG_AUTH_RENEW_NOW           override current epoch seconds (test only)
#   MURONG_AUTH_RENEW_LOG           log file (default: <module>/daemon.log)
#   MURONG_AUTH_RENEW_STATE_DIR     pid/state dir (default: <module>/runtime/auth_renew)
#   MURONG_AUTH_RENEW_WEB_HANDLER   override web_handler.sh path (test only)
#
# Exit codes: 0 = checked/renewed/nothing due; 1 = check failed; 2 = not logged in.

umask 077

SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR=.
MODDIR=${MURONG_AUTH_RENEW_MODDIR:-${MURONGCHAOPIN_MOD_PATH:-${SCRIPT_DIR%/*}}}
[ -d "$MODDIR" ] || { echo "Error: module dir not found: $MODDIR" >&2; exit 1; }
export MURONGCHAOPIN_MOD_PATH="$MODDIR"

GATE_FILE="$MODDIR/scripts/display_license_gate.sh"
WEB_HANDLER=${MURONG_AUTH_RENEW_WEB_HANDLER:-$MODDIR/scripts/web_handler.sh}
[ -f "$GATE_FILE" ] || { echo "Error: license gate missing: $GATE_FILE" >&2; exit 1; }
[ -f "$WEB_HANDLER" ] || { echo "Error: web handler missing: $WEB_HANDLER" >&2; exit 1; }

# shellcheck disable=SC1090
. "$GATE_FILE"

STATE_DIR=${MURONG_AUTH_RENEW_STATE_DIR:-$MODDIR/runtime/auth_renew}
LOG_FILE=${MURONG_AUTH_RENEW_LOG:-$MODDIR/daemon.log}
PID_FILE="$STATE_DIR/pid"
STATE_FILE="$STATE_DIR/state.txt"
LEASE_WINDOW=${MURONG_AUTH_RENEW_LEASE_WINDOW:-86400}
INTERVAL=${MURONG_AUTH_RENEW_INTERVAL:-21600}
RETRY=${MURONG_AUTH_RENEW_RETRY:-1800}
MAX_FAIL=${MURONG_AUTH_RENEW_MAX_FAIL:-3}
BOOT_DELAY=${MURONG_AUTH_RENEW_BOOT_DELAY:-90}

MODE="once"
FORCE=0
QUIET=0
STOP=0

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" 2>/dev/null | sed -n '1,30p'
}

now_epoch() {
    if [ -n "${MURONG_AUTH_RENEW_NOW:-}" ]; then
        printf '%s\n' "$MURONG_AUTH_RENEW_NOW"
        return 0
    fi
    date +%s 2>/dev/null
}

sanitize_reason() {
    printf '%s' "$1" | tr '\n\r' '  ' | \
        sed 's/[A-Za-z0-9._~-]\{40,\}/<redacted>/g' | cut -c1-180
}

log_line() {
    _msg=$(printf '%s' "$*" | tr '\n\r' '  ' | cut -c1-400)
    mkdir -p "$STATE_DIR" 2>/dev/null
    printf '[%s] auth_renew: %s\n' "$(date '+%m-%d %H:%M:%S' 2>/dev/null)" "$_msg" \
        >> "$LOG_FILE" 2>/dev/null
    [ "$QUIET" = "1" ] || printf 'auth_renew: %s\n' "$_msg"
}

save_state() {
    # $1 result, $2 error, $3 token_exp, $4 lease_exp, $5 grace, $6 renewed_at
    mkdir -p "$STATE_DIR" 2>/dev/null
    _tmp="$STATE_FILE.tmp.$$"
    _renewed="$6"
    if [ -z "$_renewed" ] && [ -f "$STATE_FILE" ]; then
        # Keep the last successful renewal time across non-renewal checks.
        _renewed=$(sed -n 's/^last_lease_renewed_at=//p' "$STATE_FILE" 2>/dev/null | head -n 1)
    fi
    {
        printf 'last_run=%s\n' "$(now_epoch)"
        printf 'last_result=%s\n' "$1"
        printf 'last_error=%s\n' "$2"
        printf 'token_exp=%s\n' "$3"
        printf 'lease_expires_at=%s\n' "$4"
        printf 'grace_until=%s\n' "$5"
        printf 'last_lease_renewed_at=%s\n' "$_renewed"
    } > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$STATE_FILE" 2>/dev/null
    rm -f "$_tmp" 2>/dev/null
    chmod 600 "$STATE_FILE" 2>/dev/null
    return 0
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

kv_value() {
    # $1 = key=value block, $2 = key -> value (first occurrence)
    printf '%s\n' "$1" | awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }'
}

json_string_field() {
    # $1 = one-line JSON, $2 = key -> first string value (no escape handling needed)
    printf '%s' "$1" | sed -n 's/.*"'$2'":"\([^"]*\)".*/\1/p' | head -n 1
}

b64url_encode() {
    if [ -x "$GATE_MOD_PATH/bin/openssl" ]; then
        printf '%s' "$1" | "$GATE_MOD_PATH/bin/openssl" base64 -A 2>/dev/null | \
            tr -d '\r\n' | tr '+/' '-_' | tr -d '='
    else
        printf '%s' "$1" | base64 2>/dev/null | tr -d '\r\n' | tr '+/' '-_' | tr -d '='
    fi
}

token_expiry() {
    # $1 = signed token -> exp (epoch) or empty when unreadable.
    # The backend signs base64url(claims) "." base64url(hmac) (2 parts,
    # internal/pkg/token/signed.go), so the claims are part 1. Also accept a
    # 3-part JWT layout by trying part 1 and part 2 and requiring "exp".
    _tok="$1"
    [ -n "$_tok" ] || return 0
    _tmp=$(mktemp 2>/dev/null) || return 0
    _seg=1
    while [ "$_seg" -le 2 ]; do
        _part=$(printf '%s' "$_tok" | cut -d. -f"$_seg")
        _seg=$((_seg + 1))
        case "$_part" in
            ''|*[!A-Za-z0-9_-]*) continue ;;
        esac
        if gate_b64url_decode "$_part" "$_tmp" 2>/dev/null &&
           grep -q '"exp"' "$_tmp" 2>/dev/null; then
            gate_json_number "$_tmp" exp
            rm -f "$_tmp" 2>/dev/null
            return 0
        fi
    done
    rm -f "$_tmp" 2>/dev/null
    return 0
}

extract_data_json() {
    # apiEnvelope = {success,message,data,timestamp[,refresh_token]}: data last object.
    printf '%s' "$1" | tr -d '\n\r' |
        sed -n 's/^.*"data":\(.*\),"timestamp":.*$/\1/p' | head -n 1
}

human_time() {
    [ -n "$1" ] && [ "$1" -gt 0 ] 2>/dev/null || { printf '%s' "-"; return 0; }
    date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"
}

module_stopped() {
    [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]
}

acquire_pid() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    if [ -f "$PID_FILE" ]; then
        _old=$(sed -n '1p' "$PID_FILE" 2>/dev/null | tr -d '[:space:]')
        case "$_old" in
            ''|*[!0-9]*) _old="" ;;
        esac
        if [ -n "$_old" ] && [ -r "/proc/$_old/cmdline" ] && \
           tr '\000' ' ' < "/proc/$_old/cmdline" 2>/dev/null | grep -Fq "display_auth_renew.sh"; then
            return 1
        fi
    fi
    printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null || return 1
    return 0
}

cleanup_pid() {
    if [ -f "$PID_FILE" ]; then
        _owned=$(sed -n '1p' "$PID_FILE" 2>/dev/null | tr -d '[:space:]')
        [ "$_owned" = "$$" ] && rm -f "$PID_FILE" 2>/dev/null
    fi
    return 0
}

wait_seconds() {
    _remaining="$1"
    case "$_remaining" in
        ''|*[!0-9]*) return 0 ;;
    esac
    while [ "$_remaining" -gt 0 ] && [ "$STOP" = "0" ]; do
        if [ "$_remaining" -gt 10 ]; then
            sleep 10
            _remaining=$((_remaining - 10))
        else
            sleep "$_remaining"
            _remaining=0
        fi
    done
    return 0
}

renew_lease() {
    # Uses the authenticated channel only; all credentials stay in config/auth.
    _info=$(sh "$WEB_HANDLER" auth_device_info 2>/dev/null)
    _device_id=$(kv_value "$_info" device_id)
    _sn=$(kv_value "$_info" sn)
    _imei1=$(kv_value "$_info" imei1)
    _imei2=$(kv_value "$_info" imei2)
    _hash=$(kv_value "$_info" device_id_hash)
    _model=$(kv_value "$_info" device_model)
    _soc=$(kv_value "$_info" soc_model)
    _fingerprint=$(kv_value "$_info" build_fingerprint)
    [ -n "$_sn" ] || _sn="$_device_id"
    if [ -z "$_device_id" ] && [ -z "$_hash" ]; then
        log_line "fail: device identity unavailable; lease not renewed"
        return 1
    fi
    _body=$(printf '{"device_id":"%s","sn":"%s","imei1":"%s","imei2":"%s","device_id_hash":"%s","device_model":"%s","soc_model":"%s","build_fingerprint":"%s"}' \
        "$(json_escape "$_device_id")" "$(json_escape "$_sn")" \
        "$(json_escape "$_imei1")" "$(json_escape "$_imei2")" \
        "$(json_escape "$_hash")" "$(json_escape "$_model")" \
        "$(json_escape "$_soc")" "$(json_escape "$_fingerprint")")
    _body_b64=$(b64url_encode "$_body")
    if [ -z "$_body_b64" ]; then
        log_line "fail: lease request encoding failed"
        return 1
    fi
    _nonce=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '[:space:]')
    [ -n "$_nonce" ] || _nonce="$(date +%s)-$$"
    _resp=$(sh "$WEB_HANDLER" api_request POST "v1/display/licenses/lease" 1 \
        "$_body_b64" "$_nonce" 0 2>/dev/null)
    _rc=$?
    if [ "$_rc" -ne 0 ] || [ -z "$_resp" ]; then
        log_line "fail: lease request failed rc=$_rc"
        return 1
    fi
    case "$_resp" in
        Error:*)
            log_line "fail: lease request rejected: $(sanitize_reason "$_resp")"
            return 1
            ;;
    esac
    if ! printf '%s' "$_resp" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
        log_line "fail: lease rejected: $(sanitize_reason "$_resp")"
        return 1
    fi
    _data=$(extract_data_json "$_resp")
    if [ -z "$_data" ]; then
        log_line "fail: lease response has no data payload"
        return 1
    fi
    _lease_b64=$(b64url_encode "$_data")
    if [ -z "$_lease_b64" ]; then
        log_line "fail: lease payload encoding failed"
        return 1
    fi
    _save=$(sh "$WEB_HANDLER" auth_save_lease "$_lease_b64" 2>/dev/null)
    case "$_save" in
        *Success*)
            _new_exp=$(gate_json_number "$GATE_LEASE_FILE" expires_at)
            _new_grace=$(gate_json_number "$GATE_LEASE_FILE" grace_until)
            log_line "lease renewed: expires_at=$_new_exp grace_until=$_new_grace"
            return 0
            ;;
        *)
            log_line "fail: renewed lease could not be saved: $(sanitize_reason "$_save")"
            return 1
            ;;
    esac
}

run_check() {
    _now=$(now_epoch)
    _token=$(gate_json_field "$GATE_ACCOUNT_FILE" token)
    if [ -z "$_token" ]; then
        log_line "skip: not logged in"
        save_state "skipped" "not logged in" "" "" "" ""
        return 2
    fi
    _token_exp=$(token_expiry "$_token")

    # Authenticated read: also lets the backend rotate the token through
    # X-Refresh-Token (api_request folds it into refresh_token).
    _licenses=$(sh "$WEB_HANDLER" api_request GET "v1/display/licenses" 1 "" "" 0 2>/dev/null)
    _rc=$?
    _failed=0
    if [ "$_rc" -ne 0 ] || [ -z "$_licenses" ]; then
        log_line "fail: license list unavailable rc=$_rc"
        save_state "failed" "license list unavailable" "$_token_exp" "" "" ""
        return 1
    fi
    case "$_licenses" in
        Error:*)
            log_line "fail: license list rejected: $(sanitize_reason "$_licenses")"
            save_state "failed" "license list rejected" "$_token_exp" "" "" ""
            return 1
            ;;
    esac
    if ! printf '%s' "$_licenses" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
        if printf '%s' "$_licenses" | grep -q '令牌无效或已过期'; then
            log_line "fail: login token expired; user has to log in again"
            save_state "failed" "login token expired" "$_token_exp" "" "" ""
        else
            log_line "fail: license list rejected: $(sanitize_reason "$_licenses")"
            save_state "failed" "license list rejected" "$_token_exp" "" "" ""
        fi
        return 1
    fi

    _new_token=$(json_string_field "$_licenses" refresh_token)
    if [ -n "$_new_token" ] && [ "$_new_token" != "$_token" ]; then
        case "$_new_token" in
            *[!A-Za-z0-9._~-]*)
                log_line "warn: rotated token ignored (unexpected format)"
                ;;
            *)
                _save=$(sh "$WEB_HANDLER" auth_update_token "$_new_token" 2>/dev/null)
                case "$_save" in
                    *Success*)
                        _token=$(gate_json_field "$GATE_ACCOUNT_FILE" token)
                        _token_exp=$(token_expiry "$_token")
                        log_line "token refreshed: exp=$_token_exp"
                        ;;
                    *)
                        _failed=1
                        log_line "fail: rotated token could not be saved: $(sanitize_reason "$_save")"
                        ;;
                esac
                ;;
        esac
    fi

    # A free account has no lease: only the login token needs renewal. Do not
    # warn/fail on every cycle when the paid package is not installed.
    if [ ! -s "$GATE_LEASE_FILE" ] && ! gate_premium_installed; then
        if [ "$_failed" = "1" ]; then
            save_state "failed" "token rotation failed" "$_token_exp" "" "" ""
            return 1
        fi
        log_line "ok: token-only account (no paid lease) token_exp=$_token_exp"
        save_state "ok" "token-only account" "$_token_exp" "" "" ""
        return 0
    fi

    _lease_exp=$(gate_json_number "$GATE_LEASE_FILE" expires_at)
    _lease_grace=$(gate_json_number "$GATE_LEASE_FILE" grace_until)
    gate_lease_verify >/dev/null 2>&1
    _lease_state="$GATE_LEASE_MODE"
    _need_lease=0
    _why=""
    if [ "$_lease_state" != "valid" ]; then
        _need_lease=1
        _why="state=$_lease_state"
    elif [ -z "$_lease_exp" ]; then
        _need_lease=1
        _why="no expiry in lease"
    else
        _left=$((_lease_exp - _now))
        if [ "$_left" -le "$LEASE_WINDOW" ]; then
            _need_lease=1
            _why="expires_in=${_left}s"
        fi
    fi
    if [ "$FORCE" = "1" ]; then
        _need_lease=1
        _why="forced"
    fi

    if [ "$_need_lease" = "0" ]; then
        _left=$((_lease_exp - _now))
        log_line "ok: lease valid expires_in=${_left}s token_exp=$_token_exp"
        save_state "ok" "" "$_token_exp" "$_lease_exp" "$_lease_grace" ""
        return 0
    fi

    _renewed_at=$(now_epoch)
    if ! renew_lease; then
        save_state "failed" "lease renew failed" "$_token_exp" "$_lease_exp" "$_lease_grace" ""
        return 1
    fi
    _lease_exp=$(gate_json_number "$GATE_LEASE_FILE" expires_at)
    _lease_grace=$(gate_json_number "$GATE_LEASE_FILE" grace_until)
    _token_exp=$(token_expiry "$(gate_json_field "$GATE_ACCOUNT_FILE" token)")
    save_state "renewed" "$_why" "$_token_exp" "$_lease_exp" "$_lease_grace" "$_renewed_at"
    if [ "$_failed" = "1" ]; then
        log_line "renewed but token rotation failed"
        return 1
    fi
    return 0
}

print_status() {
    _now=$(now_epoch)
    _token=$(gate_json_field "$GATE_ACCOUNT_FILE" token)
    echo "module_dir=$MODDIR"
    if [ -n "$_token" ]; then
        _token_exp=$(token_expiry "$_token")
        echo "logged_in=yes"
        echo "username=$(gate_json_field "$GATE_ACCOUNT_FILE" username)"
        echo "token_exp=${_token_exp:-unknown} ($(human_time "$_token_exp"))"
        if [ -n "$_token_exp" ] && [ "$_token_exp" -gt 0 ] 2>/dev/null; then
            _token_left=$((_token_exp - _now))
            echo "token_expires_in=${_token_left}s"
        fi
    else
        echo "logged_in=no"
    fi
    gate_lease_verify >/dev/null 2>&1
    echo "lease_state=$GATE_LEASE_MODE"
    echo "lease_reason=${GATE_LEASE_REASON:-}"
    _lease_exp=$(gate_json_number "$GATE_LEASE_FILE" expires_at)
    _lease_grace=$(gate_json_number "$GATE_LEASE_FILE" grace_until)
    echo "lease_expires_at=${_lease_exp:-} ($(human_time "$_lease_exp"))"
    echo "grace_until=${_lease_grace:-} ($(human_time "$_lease_grace"))"
    if [ -n "$_lease_exp" ] && [ "$_lease_exp" -gt 0 ] 2>/dev/null; then
        echo "lease_expires_in=$((_lease_exp - _now))s"
    fi
    echo "lease_renew_window=${LEASE_WINDOW}s"
    if [ -f "$STATE_FILE" ]; then
        echo "--- last run ---"
        cat "$STATE_FILE" 2>/dev/null
    fi
    if [ -f "$PID_FILE" ]; then
        echo "loop_pid=$(sed -n '1p' "$PID_FILE" 2>/dev/null)"
    fi
    return 0
}

run_loop() {
    if ! acquire_pid; then
        log_line "loop already running (pid $(sed -n '1p' "$PID_FILE" 2>/dev/null))"
        return 0
    fi
    trap 'STOP=1' INT TERM HUP
    trap 'cleanup_pid' EXIT
    log_line "loop start pid=$$ interval=${INTERVAL}s retry=${RETRY}s boot_delay=${BOOT_DELAY}s"
    wait_seconds "$BOOT_DELAY"
    _fails=0
    while [ "$STOP" = "0" ]; do
        if module_stopped; then
            log_line "module disabled/removed; loop stops"
            break
        fi
        run_check
        _rc=$?
        case "$_rc" in
            0|2)
                _fails=0
                wait_seconds "$INTERVAL"
                ;;
            *)
                _fails=$((_fails + 1))
                if [ "$_fails" -le "$MAX_FAIL" ]; then
                    _delay="$RETRY"
                else
                    _fails=0
                    _delay="$INTERVAL"
                fi
                log_line "retry in ${_delay}s"
                wait_seconds "$_delay"
                ;;
        esac
    done
    cleanup_pid
    return 0
}

for _arg in "$@"; do
    case "$_arg" in
        --loop) MODE="loop" ;;
        --once) MODE="once" ;;
        --status) MODE="status" ;;
        --force) FORCE=1 ;;
        --quiet) QUIET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option $_arg" >&2; usage >&2; exit 64 ;;
    esac
done

case "$MODE" in
    loop) run_loop ;;
    status) print_status ;;
    once) run_check ;;
esac
