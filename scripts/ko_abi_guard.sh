#!/system/bin/sh

# Dynamic kernel symbol contract guard.
#
# The vendor DLKM modules that the running kernel booted with record the
# genksyms CRC they expect for every imported symbol.  bin/ko_abi_guard reads
# that contract off the device and uses it to decide whether one of our own
# kernel modules still matches the kernel that is running right now:
#
#   * recorded CRC == device CRC        -> insmod the shipped module
#   * recorded CRC != device CRC        -> insmod an adapted runtime copy
#   * no vendor module resolves it      -> drop that one version check
#   * a required symbol is missing      -> skip the module and report why
#
# The shipped .ko files are never modified: adapted copies live under
# runtime/ko_abi/.  Nothing is guessed, and a module that cannot be verified
# is skipped instead of being force-loaded.

KO_ABI_MOD_DIR=${KO_ABI_MOD_DIR:-${MOD_DIR:-${MODDIR:-}}}
KO_ABI_BIN=${KO_ABI_BIN:-$KO_ABI_MOD_DIR/bin/ko_abi_guard}
KO_ABI_STATE_DIR=${KO_ABI_STATE_DIR:-$KO_ABI_MOD_DIR/runtime/ko_abi}
KO_ABI_LOG_FILE=${KO_ABI_LOG_FILE:-$KO_ABI_MOD_DIR/daemon.log}
KO_ABI_CONTRACT="$KO_ABI_STATE_DIR/contract.txt"
KO_ABI_PROVIDERS="$KO_ABI_STATE_DIR/providers.txt"

ko_abi_log()
{
    [ -n "$KO_ABI_LOG_FILE" ] || return 0
    printf '%s ko_abi: %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" \
        >> "$KO_ABI_LOG_FILE" 2>/dev/null
}

ko_abi_status()
{
    [ -n "$KO_ABI_STATE_DIR" ] || return 0
    mkdir -p "$KO_ABI_STATE_DIR" 2>/dev/null
    printf '%s %s %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$1" "$2" \
        >> "$KO_ABI_STATE_DIR/status.txt" 2>/dev/null
}

# Called once from post-fs-data so the contract describes this boot only.
ko_abi_reset()
{
    rm -rf "$KO_ABI_STATE_DIR" 2>/dev/null
    mkdir -p "$KO_ABI_STATE_DIR" 2>/dev/null
}

ko_abi_prepare()
{
    ko_abi_release=$(uname -r 2>/dev/null)
    [ -x "$KO_ABI_BIN" ] || {
        ko_abi_log "guard binary missing at $KO_ABI_BIN"
        return 1
    }
    [ -d "$KO_ABI_STATE_DIR" ] || mkdir -p "$KO_ABI_STATE_DIR" 2>/dev/null
    [ -d "$KO_ABI_STATE_DIR" ] || return 1
    if [ -s "$KO_ABI_CONTRACT" ] && [ -s "$KO_ABI_PROVIDERS" ] && \
       [ "$(cat "$KO_ABI_STATE_DIR/release" 2>/dev/null)" = "$ko_abi_release" ]; then
        return 0
    fi
    rm -f "$KO_ABI_CONTRACT.tmp" "$KO_ABI_PROVIDERS.tmp" 2>/dev/null
    ko_abi_scan=$("$KO_ABI_BIN" scan \
        --out "$KO_ABI_CONTRACT.tmp" \
        --out-providers "$KO_ABI_PROVIDERS.tmp" 2>&1)
    ko_abi_rc=$?
    if [ "$ko_abi_rc" -ne 0 ] || [ ! -s "$KO_ABI_CONTRACT.tmp" ]; then
        ko_abi_log "contract scan failed rc=$ko_abi_rc $(printf '%s' "$ko_abi_scan" | tail -n 1)"
        rm -f "$KO_ABI_CONTRACT.tmp" "$KO_ABI_PROVIDERS.tmp" 2>/dev/null
        return 1
    fi
    mv -f "$KO_ABI_CONTRACT.tmp" "$KO_ABI_CONTRACT" 2>/dev/null
    mv -f "$KO_ABI_PROVIDERS.tmp" "$KO_ABI_PROVIDERS" 2>/dev/null
    printf '%s\n' "$ko_abi_release" > "$KO_ABI_STATE_DIR/release"
    ko_abi_log "contract for $ko_abi_release: $(printf '%s' "$ko_abi_scan" | tr '\n' ' ')"
    return 0
}

# Sets KO_ABI_RESOLVED to the module file that may be insmod-ed.
# Falls back to the shipped file when the guard cannot describe this kernel,
# which preserves the pre-guard behaviour instead of refusing to load.
ko_abi_resolve()
{
    ko_abi_src=$1
    KO_ABI_RESOLVED=$ko_abi_src
    ko_abi_plan=direct
    ko_abi_reason=
    [ -r "$ko_abi_src" ] || {
        KO_ABI_RESOLVED=
        ko_abi_plan=missing
        return 1
    }
    ko_abi_prepare || {
        ko_abi_plan=unverified
        return 0
    }
    ko_abi_out=$("$KO_ABI_BIN" check \
        --contract "$KO_ABI_CONTRACT" \
        --providers "$KO_ABI_PROVIDERS" "$ko_abi_src" 2>&1)
    ko_abi_rc=$?
    ko_abi_reason=$(printf '%s\n' "$ko_abi_out" | sed -n 's/^reason=//p' | tail -n 1)
    case "$ko_abi_rc" in
    0)
        ko_abi_plan=verified
        return 0
        ;;
    3)
        ko_abi_dst="$KO_ABI_STATE_DIR/$(basename "$ko_abi_src")"
        if [ -f "$ko_abi_dst" ] && [ "$ko_abi_dst" -nt "$ko_abi_src" ]; then
            KO_ABI_RESOLVED=$ko_abi_dst
            ko_abi_plan=adapted
            return 0
        fi
        if "$KO_ABI_BIN" patch \
            --contract "$KO_ABI_CONTRACT" \
            --providers "$KO_ABI_PROVIDERS" \
            --output "$ko_abi_dst" "$ko_abi_src" >/dev/null 2>&1; then
            chmod 0600 "$ko_abi_dst" 2>/dev/null
            KO_ABI_RESOLVED=$ko_abi_dst
            ko_abi_plan=adapted
            return 0
        fi
        ko_abi_plan=adapt_failed
        return 1
        ;;
    *)
        ko_abi_plan=abi_rejected
        return 1
        ;;
    esac
}

# ko_abi_insmod <module.ko> <module-name> [module parameters...]
ko_abi_insmod()
{
    ko_abi_ko=$1
    ko_abi_name=$2
    shift 2
    if [ -n "$ko_abi_name" ] && [ -d "/sys/module/$ko_abi_name" ]; then
        ko_abi_status "$ko_abi_name" already_loaded
        return 0
    fi
    if ! ko_abi_resolve "$ko_abi_ko"; then
        ko_abi_status "$ko_abi_name" "skipped:$ko_abi_plan${ko_abi_reason:+:$ko_abi_reason}"
        ko_abi_log "$ko_abi_name skipped plan=$ko_abi_plan reason=$ko_abi_reason"
        return 1
    fi
    insmod "$KO_ABI_RESOLVED" "$@" >/dev/null 2>&1
    ko_abi_rc=$?
    if [ "$ko_abi_rc" -eq 0 ]; then
        ko_abi_status "$ko_abi_name" "loaded:$ko_abi_plan"
        [ "$ko_abi_plan" = adapted ] && \
            ko_abi_log "$ko_abi_name loaded from an ABI-adapted copy ($ko_abi_reason)"
        return 0
    fi
    ko_abi_status "$ko_abi_name" "insmod_failed:$ko_abi_plan:$ko_abi_rc"
    return "$ko_abi_rc"
}
