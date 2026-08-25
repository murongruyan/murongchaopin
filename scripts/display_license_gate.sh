#!/system/bin/sh
# display_license_gate.sh - local authorization gate for premium display features.
#
# The module ships only public keys; leases and package manifests are verified
# with the bundled verify_lease_sig binary (Ed25519, public-domain ref10).
#
# Layout (config/auth/, mode 0700, files 0600):
#   lease_public_key.hex   - lease verification public key (ships with module)
#   lease_key_id.txt       - expected lease key_id (ships with module)
#   package_public_key.hex - paid package manifest public key (ships with module)
#   package_key_id.txt     - expected package signature key_id (ships with module)
#   account.json           - {"username":"...","user_id":...,"token":"..."}
#   device_id.txt          - cached resolved device id (OTA-stable)
#   lease.json             - SignedLease JSON (algorithm,key_id,claims,payload,signature)
#   package.json           - installed paid package info
#   state.json             - gate state, entitlement cache, staging flags
#   package.download       - in-flight package download (staging)
#
# Exit code contract for gate_check <feature>:
#   0 authorized (lease valid), 2 grace (offline window), 1 denied.
# GATE_MODE/GATE_REASON are set for callers that source this file.

GATE_MOD_PATH="${MURONGCHAOPIN_MOD_PATH:-/data/adb/modules/murongchaopin}"
if [ ! -d "$GATE_MOD_PATH" ]; then
    GATE_MOD_PATH=$(dirname $(dirname "$0"))
fi

GATE_AUTH_DIR="$GATE_MOD_PATH/config/auth"
GATE_LEASE_PUBKEY="$GATE_AUTH_DIR/lease_public_key.hex"
GATE_LEASE_KEY_ID_FILE="$GATE_AUTH_DIR/lease_key_id.txt"
GATE_PKG_PUBKEY="$GATE_AUTH_DIR/package_public_key.hex"
GATE_PKG_KEY_ID_FILE="$GATE_AUTH_DIR/package_key_id.txt"
GATE_ACCOUNT_FILE="$GATE_AUTH_DIR/account.json"
GATE_DEVICE_FILE="$GATE_AUTH_DIR/device_id.txt"
GATE_LEASE_FILE="$GATE_AUTH_DIR/lease.json"
GATE_PACKAGE_FILE="$GATE_AUTH_DIR/package.json"
GATE_STATE_FILE="$GATE_AUTH_DIR/state.json"
GATE_DOWNLOAD_FILE="$GATE_AUTH_DIR/package.download"
GATE_DOWNLOAD_META="$GATE_AUTH_DIR/package.download.meta"
GATE_BACKEND_OVERRIDE_FILE="$GATE_AUTH_DIR/backend-compat.override"
GATE_VERIFY_BIN="$GATE_MOD_PATH/bin/verify_lease_sig"
GATE_PREMIUM_DIR="$GATE_MOD_PATH/premium"
GATE_MAX_PACKAGE_BYTES=536870912
GATE_MAX_CHUNK_BYTES=131072
GATE_FEATURES="custom_ltpo adfr_disable video_memc game_assistant"

GATE_MODE="unknown"
GATE_REASON=""
GATE_DEVICE_ID=""
GATE_DEVICE_HASH=""

gate_sha256_bin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk 'NR == 1 { print tolower($1); exit }'
    elif [ -x "$GATE_MOD_PATH/bin/openssl" ]; then
        "$GATE_MOD_PATH/bin/openssl" dgst -sha256 "$1" 2>/dev/null | awk '{ print tolower($NF) }'
    else
        return 1
    fi
}

gate_sha256_hex_to_bin() {
    # $1 = 64 hex chars -> writes 32 raw bytes to $2
    printf '%s' "$1" | sed 's/\(..\)/\\x\1/g' | xargs printf > "$2" 2>/dev/null
    [ -s "$2" ] || return 1
    return 0
}

gate_pkg_soc_supported() {
    # $1 = manifest.json, $2 = device soc (may be empty -> treat as supported)
    _soc="$2"
    [ -n "$_soc" ] || return 0
    grep -q "\"$_soc\"" "$1" 2>/dev/null
}

gate_json_array_values() {
    # $1 = manifest.json, $2 = field name -> whitespace-separated string values.
    # Strip the field name and opening bracket before splitting. This handles
    # both compact JSON (["a","b"]) and pretty JSON (["a", "b"]).
    grep -o "\"$2\"[[:space:]]*:[[:space:]]*\[[^]]*\]" "$1" 2>/dev/null |
        head -n 1 |
        sed 's/^[^[]*\[//; s/]$//; s/,/ /g' |
        tr -d '"'
}

gate_list_contains() {
    # $1 = manifest.json, $2 = field name, $3 = value -> 0 when value is an
    # exact entry of the JSON string array.
    for _gate_entry in $(gate_json_array_values "$1" "$2"); do
        [ "$_gate_entry" = "$3" ] && return 0
    done
    return 1
}

gate_pattern_matches() {
    # Match the server contract: exact, shell wildcard, or a prefix followed by
    # a non-alphanumeric version boundary. Thus 6.12 accepts 6.12.23-... but
    # never accepts 6.126....
    _gate_pattern=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    _gate_actual=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
    [ -n "$_gate_pattern" ] && [ -n "$_gate_actual" ] || return 1
    [ "$_gate_pattern" = "*" ] && return 0
    [ "$_gate_pattern" = "$_gate_actual" ] && return 0
    case "$_gate_pattern" in
        *'*'*|*'?'*|*'['*)
            case "$_gate_actual" in $_gate_pattern) return 0 ;; esac
            return 1
            ;;
    esac
    case "$_gate_actual" in
        "$_gate_pattern"*)
            _gate_suffix=${_gate_actual#"$_gate_pattern"}
            _gate_boundary=$(printf '%.1s' "$_gate_suffix")
            case "$_gate_boundary" in
                [0-9a-z]) return 1 ;;
                *) return 0 ;;
            esac
            ;;
    esac
    return 1
}

gate_list_matches_pattern() {
    # $1 = manifest.json, $2 = field name, $3 = actual value.
    for _gate_entry in $(gate_json_array_values "$1" "$2"); do
        gate_pattern_matches "$_gate_entry" "$3" && return 0
    done
    return 1
}

# During the 1.0.3 rollout the signed manifest still says drm-only while the
# server release matrix is being corrected to include dtbo. Keep this bridge
# narrow: it is written only after the authenticated download-token response,
# and it is consumed only when release id and package SHA match exactly.
gate_backend_override_clear() {
    rm -f "$GATE_BACKEND_OVERRIDE_FILE"
}

gate_backend_override_write() {
    _override_release="$1"
    _override_sha=$(printf '%s' "$2" | tr 'A-F' 'a-f')
    _override_backend="$3"
    case "$_override_release" in ''|*[!0-9]*) return 1 ;; esac
    case "$_override_sha" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#_override_sha}" -eq 64 ] || return 1
    [ "$_override_backend" = dtbo ] || return 1
    _override_tmp="$GATE_BACKEND_OVERRIDE_FILE.tmp.$$"
    printf 'release_id=%s\nsha256=%s\nbackend=%s\n' \
        "$_override_release" "$_override_sha" "$_override_backend" > "$_override_tmp" || {
        rm -f "$_override_tmp"
        return 1
    }
    chmod 600 "$_override_tmp" 2>/dev/null
    mv -f "$_override_tmp" "$GATE_BACKEND_OVERRIDE_FILE" || {
        rm -f "$_override_tmp"
        return 1
    }
    return 0
}

gate_backend_override_matches() {
    _override_release=$(sed -n 's/^release_id=//p' "$GATE_BACKEND_OVERRIDE_FILE" 2>/dev/null | head -n 1)
    _override_sha=$(sed -n 's/^sha256=//p' "$GATE_BACKEND_OVERRIDE_FILE" 2>/dev/null | head -n 1 | tr 'A-F' 'a-f')
    _override_backend=$(sed -n 's/^backend=//p' "$GATE_BACKEND_OVERRIDE_FILE" 2>/dev/null | head -n 1)
    [ "$_override_release" = "$1" ] && [ "$_override_sha" = "$(printf '%s' "$2" | tr 'A-F' 'a-f')" ] && \
        [ "$_override_backend" = "$3" ]
}

gate_b64url_pad() {
    _in=$(printf '%s' "$1" | tr -d '[:space:]')
    case $((${#_in} % 4)) in
        2) _in="${_in}==" ;;
        3) _in="${_in}=" ;;
    esac
    printf '%s' "$_in"
}

gate_b64url_decode() {
    # $1 = base64url string, $2 = output file
    _padded=$(gate_b64url_pad "$1") || return 1
    if [ -x "$GATE_MOD_PATH/bin/openssl" ]; then
        printf '%s' "$_padded" | tr '_-' '/+' | \
            "$GATE_MOD_PATH/bin/openssl" base64 -d -A > "$2" 2>/dev/null
    else
        printf '%s' "$_padded" | tr '_-' '/+' | base64 -d > "$2" 2>/dev/null
    fi
    [ -s "$2" ] || return 1
    return 0
}

gate_b64url_to_hex() {
    # $1 = base64url string -> echoes hex
    _tmp=$(mktemp)
    gate_b64url_decode "$1" "$_tmp" || { rm -f "$_tmp"; return 1; }
    if command -v xxd >/dev/null 2>&1; then
        xxd -p -c 256 "$_tmp" 2>/dev/null | tr -d '\n '
    else
        od -An -tx1 "$_tmp" 2>/dev/null | tr -d ' \n'
    fi
    rm -f "$_tmp"
}

gate_json_field() {
    # $1 = file, $2 = key -> echoes the string/number value (single occurrence)
    [ -f "$1" ] || return 0
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}

gate_json_number() {
    [ -f "$1" ] || return 0
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p" "$1" | head -n 1
}

gate_init() {
    mkdir -p "$GATE_AUTH_DIR" 2>/dev/null
    chmod 700 "$GATE_AUTH_DIR" 2>/dev/null
    for _f in "$GATE_ACCOUNT_FILE" "$GATE_LEASE_FILE" "$GATE_PACKAGE_FILE" "$GATE_STATE_FILE" "$GATE_DEVICE_FILE" "$GATE_DOWNLOAD_META"; do
        [ -f "$_f" ] && chmod 600 "$_f" 2>/dev/null
    done
    if [ -f "$GATE_VERIFY_BIN" ]; then
        [ -x "$GATE_VERIFY_BIN" ] || chmod 755 "$GATE_VERIFY_BIN" 2>/dev/null
        [ -x "$GATE_VERIFY_BIN" ] || GATE_VERIFY_BIN=""
    else
        GATE_VERIFY_BIN=""
    fi
}

gate_usb_prop() {
    # resolve the device id exactly like the murong APK: serial first, then IMEI.
    _id=""
    for _p in ro.serialno ro.boot.serialno; do
        _v=$(getprop "$_p" 2>/dev/null)
        case "$_v" in ''|unknown|Unknown|UNKNOWN|null) ;; *) _id="$_v"; break ;; esac
    done
    if [ -z "$_id" ] && [ -r /sys/devices/soc0/serial_number ]; then
        _v=$(sed -n '1{s/\r$//;p;q;}' /sys/devices/soc0/serial_number 2>/dev/null)
        case "$_v" in ''|unknown|Unknown|UNKNOWN|null|0x00000000) ;; *) _id="$_v" ;; esac
    fi
    if [ -z "$_id" ] && [ -r /proc/cpuinfo ]; then
        _v=$(grep -i '^Serial' /proc/cpuinfo 2>/dev/null | head -n 1 | sed 's/^[Ss]erial[[:space:]]*:[[:space:]]*//')
        case "$_v" in ''|unknown|Unknown|UNKNOWN|null) ;; *) _id="$_v" ;; esac
    fi
    if [ -z "$_id" ]; then
        for _p in persist.radio.imei persist.vendor.radio.imei persist.sys.imei; do
            _v=$(getprop "$_p" 2>/dev/null | tr ',' '\n' | sed -n 's/[^0-9]//g;/[0-9]\{14,\}/p' | head -n 1)
            [ -n "$_v" ] && { _id="$_v"; break; }
        done
    fi
    # cached id keeps the hash stable across OTA/prop changes
    if [ -z "$_id" ] && [ -s "$GATE_DEVICE_FILE" ]; then
        _id=$(sed -n '1{s/\r$//;p;q;}' "$GATE_DEVICE_FILE" 2>/dev/null)
    fi
    printf '%s' "$_id" | tr -d '[:space:]'
}

# Keep the display authorization identity compatible with the normal card-key
# client: device_id and sn are the same stable hardware identifier, while
# imei1/imei2 are additional fields shown to the administrator.
gate_device_sn() {
    _sn=""
    for _p in ro.serialno ro.boot.serialno; do
        _v=$(getprop "$_p" 2>/dev/null)
        case "$_v" in ''|unknown|Unknown|UNKNOWN|null|0|0x00000000) ;; *) _sn="$_v"; break ;; esac
    done
    if [ -z "$_sn" ] && [ -r /sys/devices/soc0/serial_number ]; then
        _v=$(sed -n '1{s/\r$//;p;q;}' /sys/devices/soc0/serial_number 2>/dev/null)
        case "$_v" in ''|unknown|Unknown|UNKNOWN|null|0|0x00000000) ;; *) _sn="$_v" ;; esac
    fi
    if [ -z "$_sn" ] && [ -r /proc/cpuinfo ]; then
        _sn=$(grep -i '^Serial' /proc/cpuinfo 2>/dev/null | head -n 1 | sed 's/^[Ss]erial[[:space:]]*:[[:space:]]*//' | tr -d '[:space:]')
    fi
    printf '%s\n' "$_sn" | tr -d '[:space:]'
}

gate_device_imei_values() {
    _raw=""
    for _p in persist.radio.imei persist.vendor.radio.imei gsm.imei vendor.gsm.imei persist.radio.imei1 persist.vendor.radio.imei1; do
        _v=$(getprop "$_p" 2>/dev/null)
        _v=$(printf '%s' "$_v" | tr ';' ',' | sed 's/[^0-9,]//g')
        case "$_v" in *[0-9]*) _raw="$_v"; break ;; esac
    done
    printf '%s\n' "$_raw"
}

gate_device_imei1() {
    gate_device_imei_values | cut -d, -f1 | tr -cd '0-9'
}

gate_device_imei2() {
    _value=$(gate_device_imei_values | cut -d, -f2 | tr -cd '0-9')
    printf '%s\n' "$_value"
}

gate_device_id() {
    gate_init
    GATE_DEVICE_ID=$(gate_usb_prop)
    if [ -n "$GATE_DEVICE_ID" ]; then
        _tmp="$GATE_DEVICE_FILE.tmp.$$"
        printf '%s\n' "$GATE_DEVICE_ID" > "$_tmp" 2>/dev/null && \
            mv -f "$_tmp" "$GATE_DEVICE_FILE" 2>/dev/null
        chmod 600 "$GATE_DEVICE_FILE" 2>/dev/null
    fi
    printf '%s\n' "$GATE_DEVICE_ID"
}

gate_device_id_hash() {
    _id=$(gate_device_id)
    if [ -z "$_id" ]; then
        GATE_DEVICE_HASH=""
        return 1
    fi
    _norm=$(printf '%s' "$_id" | tr '[:upper:]' '[:lower:]')
    GATE_DEVICE_HASH=$(printf '%s' "$_norm" | \
        sha256sum 2>/dev/null | awk '{ print $1 }')
    if [ -z "$GATE_DEVICE_HASH" ] && [ -x "$GATE_MOD_PATH/bin/openssl" ]; then
        GATE_DEVICE_HASH=$(printf '%s' "$_norm" | \
            "$GATE_MOD_PATH/bin/openssl" dgst -sha256 2>/dev/null | awk '{ print tolower($NF) }')
    fi
    printf '%s\n' "$GATE_DEVICE_HASH"
}

gate_pubkey_hex() {
    [ -s "$GATE_LEASE_PUBKEY" ] && sed -n '1{s/\r$//;s/[^0-9a-fA-F]//g;p;q;}' "$GATE_LEASE_PUBKEY"
}

gate_lease_key_id() {
    [ -s "$GATE_LEASE_KEY_ID_FILE" ] && sed -n '1{s/\r$//;p;q;}' "$GATE_LEASE_KEY_ID_FILE"
}

gate_pkg_pubkey_hex() {
    [ -s "$GATE_PKG_PUBKEY" ] && sed -n '1{s/\r$//;s/[^0-9a-fA-F]//g;p;q;}' "$GATE_PKG_PUBKEY"
}

gate_pkg_key_id() {
    [ -s "$GATE_PKG_KEY_ID_FILE" ] && sed -n '1{s/\r$//;p;q;}' "$GATE_PKG_KEY_ID_FILE"
}

gate_lease_verify() {
    # Verify lease.json end to end. Sets:
    #   GATE_LEASE_MODE = valid|grace|expired|invalid|missing
    #   GATE_LEASE_REASON, GATE_LEASE_DEVICE_HASH, GATE_LEASE_FEATURES (comma list)
    gate_init
    GATE_LEASE_MODE="missing"
    GATE_LEASE_REASON="lease file not found"
    GATE_LEASE_DEVICE_HASH=""
    GATE_LEASE_FEATURES=""
    [ -s "$GATE_LEASE_FILE" ] || return 1

    _pub=$(gate_pubkey_hex)
    _keyid=$(gate_lease_key_id)
    _devhash=$(gate_device_id_hash)
    [ -n "$_pub" ] || { GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="lease public key not shipped"; return 1; }
    [ -x "$GATE_VERIFY_BIN" ] || { GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="verify_lease_sig missing"; return 1; }
    [ -n "$_devhash" ] || { GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="device id could not be resolved"; return 1; }

    _lease_keyid=$(gate_json_field "$GATE_LEASE_FILE" key_id)
    _payload_b64=$(gate_json_field "$GATE_LEASE_FILE" payload)
    _signature_b64=$(gate_json_field "$GATE_LEASE_FILE" signature)
    [ -n "$_lease_keyid" ] && [ -n "$_payload_b64" ] && [ -n "$_signature_b64" ] || {
        GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="lease file is malformed"; return 1
    }
    [ "$_lease_keyid" = "$_keyid" ] || {
        GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="lease key_id does not match module key"
        return 1
    }

    _work=$(mktemp -d) || { GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="cannot create temp dir"; return 1; }
    gate_b64url_decode "$_payload_b64" "$_work/payload" || {
        rm -rf "$_work"; GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="payload decode failed"; return 1
    }
    _sig_hex=$(gate_b64url_to_hex "$_signature_b64") || {
        rm -rf "$_work"; GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="signature decode failed"; return 1
    }
    "$GATE_VERIFY_BIN" "$_pub" "$_work/payload" "$_sig_hex" || {
        rm -rf "$_work"; GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="lease signature verification failed"; return 1
    }

    # claims checks (payload is Go-marshaled compact JSON)
    _scope=$(gate_json_field "$_work/payload" scope)
    _claim_keyid=$(gate_json_field "$_work/payload" key_id)
    _claim_device=$(gate_json_field "$_work/payload" device_id_hash)
    _expires=$(gate_json_number "$_work/payload" expires_at)
    _grace=$(gate_json_number "$_work/payload" grace_until)
    _nonce=$(gate_json_field "$_work/payload" nonce)
    [ "$_scope" = "display.premium" ] || {
        rm -rf "$_work"; GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="unexpected lease scope"; return 1
    }
    [ "$_claim_keyid" = "$_keyid" ] || {
        rm -rf "$_work"; GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="claim key_id mismatch"; return 1
    }
    [ "$_claim_device" = "$_devhash" ] || {
        rm -rf "$_work"; GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="lease is bound to another device"; return 1
    }
    [ ${#_nonce} -ge 16 ] 2>/dev/null || {
        rm -rf "$_work"; GATE_LEASE_MODE="invalid"; GATE_LEASE_REASON="lease nonce is missing"; return 1
    }
    GATE_LEASE_DEVICE_HASH="$_claim_device"
    GATE_LEASE_FEATURES=$(sed -n 's/.*"features"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$_work/payload" | \
        tr -d '"' | tr ',' ' ')
    GATE_LEASE_FEATURES=$(printf '%s' "$GATE_LEASE_FEATURES" | tr ' ' ',')
    rm -rf "$_work"

    _now=$(date +%s 2>/dev/null)
    [ -n "$_now" ] && [ "$_now" -ge 0 ] 2>/dev/null || _now=0
    if [ "$_expires" -ge "$_now" ] 2>/dev/null; then
        GATE_LEASE_MODE="valid"
        GATE_LEASE_REASON=""
        return 0
    fi
    if [ -n "$_grace" ] && [ "$_grace" -ge "$_now" ] 2>/dev/null; then
        GATE_LEASE_MODE="grace"
        GATE_LEASE_REASON="lease expired; offline grace window active"
        return 0
    fi
    GATE_LEASE_MODE="expired"
    GATE_LEASE_REASON="lease and grace window expired"
    return 1
}

gate_lease_feature_allowed() {
    # $1 = feature code (custom_ltpo|adfr_disable|video_memc)
    case "$GATE_LEASE_MODE" in
        valid|grace) ;;
        *) return 1 ;;
    esac
    case ",$GATE_LEASE_FEATURES," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

gate_check() {
    # $1 = requested feature -> 0 ok, 2 grace, 1 denied
    gate_lease_verify || {
        GATE_MODE="denied"
        GATE_REASON="$GATE_LEASE_REASON"
        return 1
    }
    gate_lease_feature_allowed "$1" || {
        GATE_MODE="denied"
        GATE_REASON="feature $1 is not covered by this lease"
        return 1
    }
    # Video MEMC/插帧 payloads are validated only on RMX5200. PLK110/PJD110
    # still receive the paid Hook (settings/game assistant/Scene); their
    # MEMC feature stays denied instead of blocking the whole package.
    if [ "$1" = video_memc ]; then
        _model=$(getprop ro.product.vendor.model 2>/dev/null)
        case "$_model" in
            RMX5200) ;;
            *)
                GATE_MODE="denied"
                GATE_REASON="video_memc requires RMX5200 (device model=$_model)"
                return 1
                ;;
        esac
    fi
    if [ "$GATE_LEASE_MODE" = grace ]; then
        GATE_MODE="grace"
        GATE_REASON=""
        return 2
    fi
    GATE_MODE="valid"
    GATE_REASON=""
    return 0
}

gate_premium_installed() {
    [ -s "$GATE_PACKAGE_FILE" ] && [ -d "$GATE_PREMIUM_DIR" ] && [ -s "$GATE_PREMIUM_DIR/manifest.json" ]
}

# Paid packages can be downloaded through Windows-backed WebUI storage, where
# shell payloads may acquire CRLF line endings. Android's /system/bin/sh keeps
# the carriage return in assignments and paths, causing the paid boot scripts
# to fail silently when their callers redirect diagnostics. The package has
# already passed archive, manifest, and per-file hash validation before this
# compatibility normalization is called. Keep the fix limited to shell
# scripts and preserve the executable contract expected by the payload.
gate_normalize_premium_scripts() {
    gate_premium_installed || return 1
    _cr=$(printf '\r')
    for _script in "$GATE_PREMIUM_DIR/scripts/"*.sh; do
        [ -f "$_script" ] || continue
        grep -q "$_cr" "$_script" 2>/dev/null || continue
        _tmp="$_script.lf.$$"
        tr -d '\r' < "$_script" > "$_tmp" 2>/dev/null || {
            rm -f "$_tmp"
            return 1
        }
        chmod 0755 "$_tmp" 2>/dev/null || {
            rm -f "$_tmp"
            return 1
        }
        mv -f "$_tmp" "$_script" 2>/dev/null || {
            rm -f "$_tmp"
            return 1
        }
    done
    return 0
}

gate_state_print() {
    # prints auth_state key=value block for the WebUI
    gate_init
    echo "account=none"
    echo "username="
    echo "user_id="
    echo "entitlement=not_purchased"
    echo "license_last4="
    echo "device_bound=0"
    echo "device_model=$(getprop ro.product.vendor.model 2>/dev/null)"
    echo "lease_valid=0"
    echo "lease_expires_at=0"
    echo "grace_until=0"
    echo "premium_features="
    echo "premium_available=0"
    echo "package_version="
    echo "package_version_code=0"
    echo "package_installed=0"
    echo "package_pending=0"
    echo "reboot_required=0"

    _user=$(gate_json_field "$GATE_ACCOUNT_FILE" username)
    _userid=$(gate_json_number "$GATE_ACCOUNT_FILE" user_id)
    [ -n "$_user" ] && echo "account=logged_in"
    [ -n "$_user" ] && echo "username=$_user"
    [ -n "$_userid" ] && echo "user_id=$_userid"

    gate_lease_verify
    case "$GATE_LEASE_MODE" in
        valid) echo "lease_valid=1" ;;
        grace) echo "lease_valid=1" ;;
    esac
    _expires=$(gate_json_number "$GATE_LEASE_FILE" expires_at)
    _grace=$(gate_json_number "$GATE_LEASE_FILE" grace_until)
    [ -n "$_expires" ] && echo "lease_expires_at=$_expires"
    [ -n "$_grace" ] && echo "grace_until=$_grace"

    _cached=$(gate_json_field "$GATE_STATE_FILE" entitlement)
    [ -n "$_cached" ] && echo "entitlement=$_cached"
    _last4=$(gate_json_field "$GATE_STATE_FILE" license_last4)
    [ -n "$_last4" ] && echo "license_last4=$_last4"
    _bound=$(gate_json_field "$GATE_STATE_FILE" device_bound)
    [ "$_bound" = "1" ] && echo "device_bound=1"
    _bound_model=$(gate_json_field "$GATE_STATE_FILE" bound_device_model)
    [ -n "$_bound_model" ] && echo "bound_device_model=$_bound_model"

    _features=""
    for _f in $GATE_FEATURES; do
        if gate_lease_feature_allowed "$_f" 2>/dev/null; then
            _features="${_features:+$_features,}$_f"
        fi
    done
    [ -n "$_features" ] && {
        echo "premium_features=$_features"
        echo "premium_available=1"
    }
    case "$GATE_LEASE_MODE" in
        grace) echo "lease_valid=1" ;;
    esac

    if gate_premium_installed; then
        echo "package_installed=1"
        echo "package_version=$(gate_json_field "$GATE_PACKAGE_FILE" version)"
        _package_version_code=$(gate_json_number "$GATE_PACKAGE_FILE" version_code)
        case "$_package_version_code" in ''|*[!0-9]*) _package_version_code=0 ;; esac
        echo "package_version_code=$_package_version_code"
    fi
    [ -f "$GATE_DOWNLOAD_FILE" ] && echo "package_pending=1"
    [ "$(gate_json_field "$GATE_STATE_FILE" reboot_required)" = "1" ] && echo "reboot_required=1"
    # A missing lease/package is a normal state, not a query failure. Do not
    # leak the status of the final optional file test as this function's rc.
    return 0
}

gate_device_info_print() {
    gate_init
    _device_id=$(gate_device_id)
    _sn=$(gate_device_sn)
    [ -n "$_sn" ] || _sn="$_device_id"
    _imei1=$(gate_device_imei1)
    _imei2=$(gate_device_imei2)
    _hash=$(gate_device_id_hash)
    echo "device_id=${_device_id:-}"
    echo "sn=${_sn:-}"
    echo "imei1=${_imei1:-}"
    echo "imei2=${_imei2:-}"
    echo "device_id_hash=${_hash:-}"
    echo "device_model=$(getprop ro.product.vendor.model 2>/dev/null)"
    echo "soc_model=$(getprop ro.soc.model 2>/dev/null)"
    echo "build_fingerprint=$(getprop ro.build.fingerprint 2>/dev/null)"
    echo "kernel=$(uname -r 2>/dev/null)"
    echo "base_version=$(sed -n 's/^version=//p' "$GATE_MOD_PATH/module.prop" 2>/dev/null | head -n 1)"
    echo "backend=$(sed -n '1{s/\r$//;p;q;}' "$GATE_MOD_PATH/config/dts_backend.txt" 2>/dev/null | tr -d '[:space:]')"
}

gate_state_write() {
    # $1 key, $2 value -> persist into state.json (root object, single-line JSON)
    gate_init
    _tmp="$GATE_STATE_FILE.tmp.$$"
    if [ -s "$GATE_STATE_FILE" ]; then
        _body=$(cat "$GATE_STATE_FILE" | sed 's/^{//; s/}$//')
    else
        _body=""
    fi
    # Older builds could leave a leading comma after updating an empty or
    # partially-written state object. Normalize separators before and after
    # replacing a key so auth_state always receives valid JSON.
    _body=$(printf '%s' "$_body" | sed 's/^,*//; s/,*$//')
    _body=$(printf '%s' "$_body" | sed "s/,\{0,1\}\"$1\":[^,]*//")
    _body=$(printf '%s' "$_body" | sed 's/^,*//; s/,*$//')
    if [ -n "$_body" ]; then
        _body="$_body,\"$1\":\"$2\""
    else
        _body="\"$1\":\"$2\""
    fi
    printf '{%s}\n' "$_body" > "$_tmp" || return 1
    mv -f "$_tmp" "$GATE_STATE_FILE" || return 1
    chmod 600 "$GATE_STATE_FILE" 2>/dev/null
    return 0
}

gate_account_save() {
    # $1 username, $2 user_id, $3 token (token never logged)
    gate_init
    [ -n "$1" ] || { echo "Error: missing username"; return 1; }
    [ -n "$3" ] || { echo "Error: missing token"; return 1; }
    _tmp="$GATE_ACCOUNT_FILE.tmp.$$"
    printf '{"username":"%s","user_id":%s,"token":"%s"}\n' "$1" "$2" "$3" > "$_tmp" || return 1
    mv -f "$_tmp" "$GATE_ACCOUNT_FILE" || return 1
    chmod 600 "$GATE_ACCOUNT_FILE" 2>/dev/null
    echo "Success: account saved"
    return 0
}

gate_account_clear() {
    gate_init
    rm -f "$GATE_ACCOUNT_FILE"
    echo "Success: account token cleared (lease and paid package kept)"
    return 0
}

gate_lease_save() {
    # $1 = base64url(lease.json); verify everything before persisting
    gate_init
    [ -n "$1" ] || { echo "Error: empty lease"; return 1; }
    _tmpdir=$(mktemp -d) || { echo "Error: temp dir failed"; return 1; }
    gate_b64url_decode "$1" "$_tmpdir/lease.json" || {
        rm -rf "$_tmpdir"; echo "Error: lease payload is not valid base64url"; return 1
    }
    # signature + key_id sanity before swapping in
    _pub=$(gate_pubkey_hex)
    _keyid=$(gate_lease_key_id)
    _lease_keyid=$(gate_json_field "$_tmpdir/lease.json" key_id)
    _payload_b64=$(gate_json_field "$_tmpdir/lease.json" payload)
    _signature_b64=$(gate_json_field "$_tmpdir/lease.json" signature)
    [ -n "$_pub" ] && [ -n "$_keyid" ] && [ -x "$GATE_VERIFY_BIN" ] || {
        rm -rf "$_tmpdir"; echo "Error: verifier or public key missing"; return 1
    }
    [ "$_lease_keyid" = "$_keyid" ] || {
        rm -rf "$_tmpdir"; echo "Error: lease key_id mismatch"; return 1
    }
    gate_b64url_decode "$_payload_b64" "$_tmpdir/payload" || {
        rm -rf "$_tmpdir"; echo "Error: lease payload decode failed"; return 1
    }
    _sig_hex=$(gate_b64url_to_hex "$_signature_b64") || {
        rm -rf "$_tmpdir"; echo "Error: lease signature decode failed"; return 1
    }
    "$GATE_VERIFY_BIN" "$_pub" "$_tmpdir/payload" "$_sig_hex" || {
        rm -rf "$_tmpdir"; echo "Error: lease signature verification failed"; return 1
    }
    _claim_device=$(gate_json_field "$_tmpdir/payload" device_id_hash)
    _devhash=$(gate_device_id_hash)
    [ -n "$_devhash" ] && [ "$_claim_device" = "$_devhash" ] || {
        rm -rf "$_tmpdir"; echo "Error: lease is bound to another device"; return 1
    }
    mv -f "$_tmpdir/lease.json" "$GATE_LEASE_FILE" || {
        rm -rf "$_tmpdir"; echo "Error: cannot persist lease"; return 1
    }
    chmod 600 "$GATE_LEASE_FILE" 2>/dev/null
    rm -rf "$_tmpdir"
    gate_lease_verify
    case "$GATE_LEASE_MODE" in
        valid|grace)
            # A fresh server-signed lease is the only operation allowed to
            # re-enable an installed package after a revoke/disable boot. A
            # normal lease renewal leaves reboot_required untouched.
            _was_removed=$(gate_json_field "$GATE_STATE_FILE" remove_premium)
            if [ "$_was_removed" = "1" ] && gate_premium_installed; then
                gate_state_write remove_premium "0" || return 1
                gate_state_write reboot_required "1" || return 1
            fi
            if [ "$GATE_LEASE_MODE" = "valid" ]; then
                echo "Success: lease saved and verified"
            else
                echo "Success: lease saved (offline grace active)"
            fi
            ;;
        *) echo "Error: lease accepted but state check failed: $GATE_LEASE_REASON"; return 1 ;;
    esac
    return 0
}

gate_entitlement_cache() {
    # $1 status, $2 license_last4, $3 device_model -> state.json cache
    gate_init
    [ -n "$1" ] || return 1
    gate_state_write entitlement "$1" || return 1
    gate_state_write license_last4 "$2" || return 1
    _bound=0
    case "$1" in active|grace) _bound=1 ;; esac
    gate_state_write device_bound "$_bound" || return 1
    [ -n "$3" ] && gate_state_write bound_device_model "$3" || true
    # Server-side disable/revoke/refund must never hot-unload display code.
    # Persist the decision so the next complete boot takes the free path.
    case "$1" in
        disabled|revoked|refunded)
            gate_state_write remove_premium "1" || return 1
            ;;
    esac
    echo "Success: entitlement cached"
    return 0
}

# ---- paid package staging ---------------------------------------------------

gate_package_write() {
    # $1 offset, $2 base64url chunk (<= 96KB decoded)
    gate_init
    _offset="$1"
    _chunk="$2"
    case "$_offset" in ''|*[!0-9]*) echo "Error: invalid offset"; return 1 ;; esac
    [ -n "$_chunk" ] || { echo "Error: empty chunk"; return 1; }
    _tmpchunk=$(mktemp) || { echo "Error: temp chunk failed"; return 1; }
    gate_b64url_decode "$_chunk" "$_tmpchunk" || {
        rm -f "$_tmpchunk"; echo "Error: chunk is not valid base64url"; return 1
    }
    _size=$(wc -c < "$_tmpchunk" 2>/dev/null | tr -d ' ')
    [ "$_size" -le "$GATE_MAX_CHUNK_BYTES" ] 2>/dev/null || {
        rm -f "$_tmpchunk"; echo "Error: chunk too large"; return 1
    }
    if [ -f "$GATE_DOWNLOAD_META" ]; then
        _expected=$(sed -n '1{s/\r$//;p;q;}' "$GATE_DOWNLOAD_META" 2>/dev/null | tr -d '[:space:]')
    else
        _expected=0
    fi
    [ "$_offset" = "$_expected" ] || {
        rm -f "$_tmpchunk"; echo "Error: chunk offset mismatch (expected $_expected)"; return 1
    }
    cat "$_tmpchunk" >> "$GATE_DOWNLOAD_FILE" 2>/dev/null || {
        rm -f "$_tmpchunk"; echo "Error: cannot append chunk"; return 1
    }
    rm -f "$_tmpchunk"
    _total=$(wc -c < "$GATE_DOWNLOAD_FILE" 2>/dev/null | tr -d ' ')
    [ "$_total" -le "$GATE_MAX_PACKAGE_BYTES" ] 2>/dev/null || {
        rm -f "$GATE_DOWNLOAD_FILE" "$GATE_DOWNLOAD_META"
        echo "Error: package exceeds 512MB limit"
        return 1
    }
    printf '%s\n' "$_total" > "$GATE_DOWNLOAD_META"
    chmod 600 "$GATE_DOWNLOAD_FILE" "$GATE_DOWNLOAD_META" 2>/dev/null
    echo "Success: $_total"
    return 0
}

gate_package_abort() {
    gate_init
    rm -f "$GATE_DOWNLOAD_FILE" "$GATE_DOWNLOAD_META"
    gate_backend_override_clear
    echo "Success: download staging cleared"
    return 0
}

gate_package_state_print() {
    gate_init
    _total=0
    if [ -f "$GATE_DOWNLOAD_FILE" ]; then
        _total=$(wc -c < "$GATE_DOWNLOAD_FILE" 2>/dev/null | tr -d ' ')
    fi
    echo "downloaded_bytes=${_total:-0}"
    echo "stage=$(gate_json_field "$GATE_STATE_FILE" package_stage)"
    [ -n "$(gate_json_field "$GATE_STATE_FILE" package_stage)" ] || echo "stage=idle"
}

gate_package_commit() {
    # $1 expected sha256 (hex), $2 release_id, $3 version, $4 version_code (optional)
    gate_init
    _sha="$1"
    _release="$2"
    _version="$3"
    _version_code="${4:-}"
    [ -n "$_sha" ] && [ -n "$_release" ] && [ -n "$_version" ] || {
        echo "Error: missing sha256/release_id/version"
        return 1
    }
    [ -f "$GATE_DOWNLOAD_FILE" ] || { echo "Error: no staged download"; return 1; }
    _actual=$(gate_sha256_bin "$GATE_DOWNLOAD_FILE")
    [ "$_actual" = "$_sha" ] || {
        echo "Error: package sha256 mismatch (expected $_sha, got $_actual)"
        return 1
    }

    _staging="$GATE_AUTH_DIR/package.staging"
    rm -rf "$_staging"
    mkdir -p "$_staging" || { echo "Error: cannot create staging dir"; return 1; }
    ( cd "$_staging" && unzip -o -q "$GATE_DOWNLOAD_FILE" ) 2>/dev/null || {
        rm -rf "$_staging"; echo "Error: unzip failed"; return 1
    }
    # security: no symlinks, nothing outside staging
    if find "$_staging" -type l 2>/dev/null | head -n 1 | grep -q .; then
        rm -rf "$_staging"; echo "Error: symbolic links are not allowed"; return 1
    fi
    [ -f "$_staging/manifest.json" ] || { rm -rf "$_staging"; echo "Error: manifest.json missing"; return 1; }

    # Package authorization comes from the server-issued one-time download
    # token and the whole-archive SHA-256 checked above. Legacy packages may
    # still contain manifest.sig; verify it when the old public key is
    # available, but an unsigned package is valid when all manifest/file
    # hashes pass. This keeps old 1.0.3 packages installable without making a
    # production signing key a release prerequisite.
    _pkg_pub=$(gate_pkg_pubkey_hex)
    _pkg_keyid=$(gate_pkg_key_id)
    _manifest_signed=0
    if [ -f "$_staging/manifest.sig" ]; then
        _sig_b64=$(sed -n '1{s/\r$//;p;q;}' "$_staging/manifest.sig" | tr -d '[:space:]')
        if [ -n "$_pkg_pub" ] && [ -x "$GATE_VERIFY_BIN" ]; then
            _sig_hex=$(gate_b64url_to_hex "$_sig_b64") || {
                rm -rf "$_staging"; echo "Error: manifest signature decode failed"; return 1
            }
            "$GATE_VERIFY_BIN" "$_pkg_pub" "$_staging/manifest.json" "$_sig_hex" || {
                rm -rf "$_staging"; echo "Error: manifest signature verification failed"; return 1
            }
            _manifest_signed=1
        else
            echo "Notice: manifest signature present but local verifier is unavailable; using token and SHA-256 checks"
        fi
    fi

    # manifest identity + compatibility
    _schema=$(gate_json_number "$_staging/manifest.json" schema_version)
    _manifest_version=$(gate_json_field "$_staging/manifest.json" version)
    _manifest_version_code=$(gate_json_number "$_staging/manifest.json" version_code)
    _manifest_keyid=$(gate_json_field "$_staging/manifest.json" signature_key_id)
    _min_base=$(gate_json_field "$_staging/manifest.json" min_base_version)
    _base=$(sed -n 's/^version=//p' "$GATE_MOD_PATH/module.prop" 2>/dev/null | head -n 1 | tr -d '[:space:]')
    _model=$(getprop ro.product.vendor.model 2>/dev/null)
    _soc=$(getprop ro.soc.model 2>/dev/null)
    _kernel=$(uname -r 2>/dev/null)
    _backend=$(sed -n '1{s/\r$//;p;q;}' "$GATE_MOD_PATH/config/dts_backend.txt" 2>/dev/null | tr -d '[:space:]')
    [ "$_schema" = "1" ] || { rm -rf "$_staging"; echo "Error: unsupported manifest schema"; return 1; }
    [ -n "$_manifest_version" ] && [ "$_manifest_version" = "$_version" ] || {
        rm -rf "$_staging"; echo "Error: package version does not match signed manifest"; return 1
    }
    case "$_manifest_version_code" in
        ''|*[!0-9]*) rm -rf "$_staging"; echo "Error: manifest version_code is invalid"; return 1 ;;
    esac
    if [ -n "$_version_code" ]; then
        case "$_version_code" in
            *[!0-9]*) rm -rf "$_staging"; echo "Error: package version_code is invalid"; return 1 ;;
        esac
        [ "$_version_code" = "$_manifest_version_code" ] || {
            rm -rf "$_staging"; echo "Error: package version_code does not match signed manifest"; return 1
        }
    else
        _version_code="$_manifest_version_code"
    fi
    if [ "$_manifest_signed" = 1 ]; then
        [ -n "$_manifest_keyid" ] && [ -n "$_pkg_keyid" ] && [ "$_manifest_keyid" = "$_pkg_keyid" ] || {
            rm -rf "$_staging"; echo "Error: manifest signature key_id mismatch"; return 1
        }
    fi
    [ -n "$_min_base" ] || { rm -rf "$_staging"; echo "Error: manifest missing min_base_version"; return 1; }
    if ! awk -v a="$_base" -v b="$_min_base" 'BEGIN { split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) { x[i] += 0; y[i] += 0 } ok = (x[1] > y[1]) || (x[1] == y[1] && x[2] > y[2]) || (x[1] == y[1] && x[2] == y[2] && x[3] >= y[3]); exit ok ? 0 : 1 }' 2>/dev/null; then
        rm -rf "$_staging"; echo "Error: base module version too old (need >= $_min_base, have $_base)"; return 1
    fi
    if [ -n "$_model" ]; then
        gate_list_contains "$_staging/manifest.json" supported_models "$_model" || {
            rm -rf "$_staging"; echo "Error: device model not supported"; return 1
        }
    fi
    if [ -n "$_soc" ]; then
        gate_list_contains "$_staging/manifest.json" supported_socs "$_soc" || {
            rm -rf "$_staging"; echo "Error: device SoC not supported"; return 1
        }
    fi
    _kernel_allowed=$(gate_json_array_values "$_staging/manifest.json" supported_kernels)
    gate_list_matches_pattern "$_staging/manifest.json" supported_kernels "$_kernel" || {
        rm -rf "$_staging"
        echo "Error: kernel not supported (have: ${_kernel:-unknown}; allowed: ${_kernel_allowed:-none})"
        return 1
    }
    [ -n "$_backend" ] || _backend=dtbo
    if ! gate_list_contains "$_staging/manifest.json" supported_backends "$_backend"; then
        if [ "$_backend" = dtbo ] && gate_backend_override_matches "$_release" "$_sha" "$_backend"; then
            echo "Notice: accepting server-authorized DTBO compatibility bridge for signed 1.0.3 manifest"
        else
            rm -rf "$_staging"; echo "Error: display backend not supported"; return 1
        fi
    fi

    # per-file validation (manifest files array: one object per line)
    _declared=0
    _files_list=$(mktemp) || { rm -rf "$_staging"; echo "Error: temp file failed"; return 1; }
    _targets_list=$(mktemp) || {
        rm -f "$_files_list"; rm -rf "$_staging"; echo "Error: temp file failed"; return 1
    }
    grep '^    { "path"' "$_staging/manifest.json" > "$_files_list" 2>/dev/null
    while IFS= read -r _line; do
        _path=$(printf '%s' "$_line" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _fsha=$(printf '%s' "$_line" | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _fsize=$(printf '%s' "$_line" | sed -n 's/.*"size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        _mode=$(printf '%s' "$_line" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _target=$(printf '%s' "$_line" | sed -n 's/.*"target_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        [ -n "$_path" ] || continue
        _declared=$((_declared + 1))
        case "$_path" in
            payload/*) ;;
            *) rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"; echo "Error: manifest path must start with payload/"; return 1 ;;
        esac
        case "$_path" in *..*|/*) rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"; echo "Error: unsafe manifest path"; return 1 ;; esac
        case "$_target" in
            ''|/*|*..*|*\\*)
                rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"
                echo "Error: unsafe manifest target_path"; return 1
                ;;
        esac
        case "$_mode" in
            0644|0755) ;;
            *) rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"; echo "Error: unsupported manifest mode"; return 1 ;;
        esac
        if grep -Fxq "$_target" "$_targets_list" 2>/dev/null; then
            rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"
            echo "Error: duplicate manifest target_path: $_target"; return 1
        fi
        printf '%s\n' "$_target" >> "$_targets_list"
        [ -f "$_staging/$_path" ] || {
            rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"; echo "Error: declared file missing: $_path"; return 1
        }
        _actual_sha=$(gate_sha256_bin "$_staging/$_path")
        [ "$_actual_sha" = "$_fsha" ] || {
            rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"; echo "Error: sha256 mismatch for $_path"; return 1
        }
        _actual_size=$(wc -c < "$_staging/$_path" 2>/dev/null | tr -d ' ')
        [ "$_actual_size" = "$_fsize" ] || {
            rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"; echo "Error: size mismatch for $_path"; return 1
        }
    done < "$_files_list"
    [ "$_declared" -gt 0 ] || {
        rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"; echo "Error: manifest declares no files"; return 1
    }

    # reject undeclared files (outside manifest.json and optional manifest.sig)
    _extra=$(cd "$_staging" && find . -type f ! -name manifest.json ! -name manifest.sig | \
        sed 's|^\./||' | while IFS= read -r _p; do
        case "$_p" in
            payload/*) grep -q "\"path\"[[:space:]]*:[[:space:]]*\"$_p\"" manifest.json || echo "$_p" ;;
            *) echo "$_p" ;;
        esac
    done | head -n 1)
    [ -z "$_extra" ] || {
        rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"; echo "Error: undeclared file in package: $_extra"; return 1
    }

    # Materialize only signed target_path entries. The ZIP's payload/ prefix
    # is a transport namespace and must never become premium/payload/ at run
    # time. Build the complete tree before touching the active package.
    _install="$GATE_AUTH_DIR/package.installing"
    rm -rf "$_install"
    mkdir -p "$_install" || {
        rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging"; echo "Error: cannot create install staging"; return 1
    }
    while IFS= read -r _line; do
        _path=$(printf '%s' "$_line" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _mode=$(printf '%s' "$_line" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        _target=$(printf '%s' "$_line" | sed -n 's/.*"target_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        [ -n "$_path" ] || continue
        _target_dir=${_target%/*}
        if [ "$_target_dir" != "$_target" ]; then
            mkdir -p "$_install/$_target_dir" || {
                rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging" "$_install"
                echo "Error: cannot create target directory"; return 1
            }
        fi
        cp "$_staging/$_path" "$_install/$_target" || {
            rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging" "$_install"
            echo "Error: cannot materialize target $_target"; return 1
        }
        chmod "$_mode" "$_install/$_target" || {
            rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging" "$_install"
            echo "Error: cannot set target mode $_target"; return 1
        }
    done < "$_files_list"
    cp "$_staging/manifest.json" "$_install/manifest.json" || {
        rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging" "$_install"
        echo "Error: cannot materialize manifest"; return 1
    }
    chmod 0644 "$_install/manifest.json" || {
        rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging" "$_install"
        echo "Error: cannot set manifest mode"; return 1
    }
    if [ -f "$_staging/manifest.sig" ]; then
        cp "$_staging/manifest.sig" "$_install/manifest.sig" &&
            chmod 0644 "$_install/manifest.sig" || {
            rm -f "$_files_list" "$_targets_list"; rm -rf "$_staging" "$_install"
            echo "Error: cannot materialize optional manifest signature"; return 1
        }
    fi
    rm -f "$_files_list" "$_targets_list"

    # atomic swap: keep previous paid version on failure
    _previous="$GATE_AUTH_DIR/package.previous"
    rm -rf "$_previous"
    if [ -d "$GATE_PREMIUM_DIR" ]; then
        mv "$GATE_PREMIUM_DIR" "$_previous" 2>/dev/null || {
            rm -rf "$_staging" "$_install"; echo "Error: cannot move current paid package"; return 1
        }
    fi
    if ! mv "$_install" "$GATE_PREMIUM_DIR" 2>/dev/null; then
        [ -d "$_previous" ] && mv "$_previous" "$GATE_PREMIUM_DIR" 2>/dev/null
        rm -rf "$_staging" "$_install"
        echo "Error: cannot install paid package"
        return 1
    fi
    rm -rf "$_staging"
    chmod 700 "$GATE_PREMIUM_DIR" 2>/dev/null

    _pkgtmp="$GATE_PACKAGE_FILE.tmp.$$"
    printf '{"release_id":"%s","version":"%s","version_code":%s,"sha256":"%s","installed_at":"%s"}\n' \
        "$_release" "$_version" "$_version_code" "$_sha" "$(date +%s 2>/dev/null)" > "$_pkgtmp" || true
    mv -f "$_pkgtmp" "$GATE_PACKAGE_FILE" 2>/dev/null
    chmod 600 "$GATE_PACKAGE_FILE" 2>/dev/null

    rm -f "$GATE_DOWNLOAD_FILE" "$GATE_DOWNLOAD_META"
    gate_backend_override_clear
    gate_state_write remove_premium "0" || true
    gate_state_write reboot_required "1" || true
    # Restore LSPosed module scope before the requested reboot so the premium
    # Hook is injected on the first boot after installation.
    if [ -f "$GATE_MOD_PATH/scripts/lspd_scope.sh" ]; then
        sh "$GATE_MOD_PATH/scripts/lspd_scope.sh" >/dev/null 2>&1 || true
    fi
    echo "Success: paid package installed; a full reboot is required"
    return 0
}

gate_package_boot_complete() {
    # Consume the install-time reboot marker only after the paid service stage
    # has run during a complete system boot. This is not an authorization
    # change and never loads or unloads display components.
    gate_init
    gate_premium_installed || {
        echo "Error: paid package is not installed"
        return 1
    }
    gate_state_write reboot_required "0" || {
        echo "Error: cannot clear reboot requirement"
        return 1
    }
    echo "Success: paid package boot completed"
    return 0
}

gate_package_remove() {
    # mark removal at next boot; never hot-unload display components
    gate_init
    gate_state_write remove_premium "1" || { echo "Error: cannot mark removal"; return 1; }
    echo "Success: paid package will be disabled at next boot (free path restored)"
    return 0
}
