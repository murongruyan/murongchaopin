#!/bin/sh
# Run copied public boot entrypoints with only temporary mock module payloads.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/murong-premium-staging.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

fail() {
    echo "FAIL: $ENTRY/$SCENARIO: $1" >&2
    exit 1
}

mkdir -p "$WORK/mockbin"
cat > "$WORK/mockbin/setprop" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$WORK/mockbin/setprop"
for command in mount umount insmod modprobe rmmod; do
    cat > "$WORK/mockbin/$command" <<'MOCK'
#!/bin/sh
printf '%s\n' "$0 $*" >> "$UNEXPECTED_SYSTEM_CALLS"
exit 99
MOCK
    chmod +x "$WORK/mockbin/$command"
done

run_case() {
    ENTRY=$1
    SCENARIO=$2
    MOD="$WORK/$ENTRY-$SCENARIO"
    mkdir -p "$MOD/scripts" "$MOD/premium/scripts" "$MOD/runtime" \
        "$MOD/system/odm/lib64" "$MOD/system/etc" "$MOD/config/auth"
    cp "$ROOT/$ENTRY" "$MOD/$ENTRY"
    printf 'owned-stage\n' > "$MOD/system/odm/lib64/libpwirisservicei7p.so"
    printf 'adjacent-backup\n' > "$MOD/system/odm/lib64/libpwirisservicei7p.so.backup"
    printf 'unrelated-so\n' > "$MOD/system/odm/lib64/libunrelated.so"
    printf 'unrelated-config\n' > "$MOD/system/etc/keep.conf"
    printf '0\n' > "$MOD/config/auth/remove_premium"

    cat > "$MOD/scripts/display_backend.sh" <<'MOCK'
#!/bin/sh
exit 0
MOCK
    cat > "$MOD/scripts/display_license_gate.sh" <<'MOCK'
GATE_STATE_FILE="$MODDIR/config/auth/remove_premium"
gate_json_field() {
    [ "$2" = remove_premium ] || return 1
    cat "$1"
}
gate_normalize_premium_scripts() {
    return 0
}
MOCK
    cat > "$MOD/premium/scripts/premium_post_fs_data.sh" <<'MOCK'
#!/bin/sh
printf 'private-dispatched\n' >> "${0%/*}/../../runtime/private.trace"
exit "${PRIVATE_EXIT_CODE:-0}"
MOCK

    EXPECT_STAGE=0
    EXPECT_PRIVATE=0
    PRIVATE_EXIT_CODE=0
    case "$SCENARIO" in
        valid)
            EXPECT_STAGE=1
            EXPECT_PRIVATE=1
            ;;
        private_failure)
            # Public cleanup must not replace the private feature gate's work.
            EXPECT_STAGE=1
            EXPECT_PRIVATE=1
            PRIVATE_EXIT_CODE=1
            ;;
        remove)
            printf '1\n' > "$MOD/config/auth/remove_premium"
            ;;
        skip)
            : > "$MOD/runtime/skip_kernel_modules"
            ;;
        missing_gate)
            rm "$MOD/scripts/display_license_gate.sh"
            ;;
        missing_private)
            rm "$MOD/premium/scripts/premium_post_fs_data.sh"
            ;;
        gate_source_failure)
            # Even a partially defined helper must not dispatch after failure.
            printf '\nreturn 1\n' >> "$MOD/scripts/display_license_gate.sh"
            ;;
        missing_gate_function)
            : > "$MOD/scripts/display_license_gate.sh"
            ;;
        missing_display)
            rm "$MOD/scripts/display_backend.sh"
            ;;
        *) fail 'unknown fixture' ;;
    esac

    UNEXPECTED_SYSTEM_CALLS="$WORK/unexpected-system-calls"
    export PRIVATE_EXIT_CODE UNEXPECTED_SYSTEM_CALLS
    PATH="$WORK/mockbin:$PATH" sh "$MOD/$ENTRY" > "$MOD/runtime/output" 2>&1 ||
        fail 'entrypoint failed'

    if [ "$EXPECT_STAGE" = 1 ]; then
        [ "$(cat "$MOD/system/odm/lib64/libpwirisservicei7p.so")" = owned-stage ] ||
            fail 'normal private dispatch changed its staged SO'
    else
        [ ! -e "$MOD/system/odm/lib64/libpwirisservicei7p.so" ] ||
            fail 'skipped private dispatch left its staged SO'
    fi
    if [ "$EXPECT_PRIVATE" = 1 ]; then
        [ "$(cat "$MOD/runtime/private.trace")" = private-dispatched ] ||
            fail 'private entrypoint was not invoked exactly once'
    else
        [ ! -e "$MOD/runtime/private.trace" ] || fail 'skipped private entrypoint ran'
    fi
    [ "$(cat "$MOD/system/odm/lib64/libpwirisservicei7p.so.backup")" = adjacent-backup ] ||
        fail 'adjacent backup was changed'
    [ "$(cat "$MOD/system/odm/lib64/libunrelated.so")" = unrelated-so ] ||
        fail 'unrelated SO was changed'
    [ "$(cat "$MOD/system/etc/keep.conf")" = unrelated-config ] ||
        fail 'unrelated system config was changed'
    [ -d "$MOD/system/odm/lib64" ] || fail 'staging directory was removed'
    [ ! -e "$UNEXPECTED_SYSTEM_CALLS" ] || fail 'a real system operation was attempted'
    if [ "$SCENARIO" = skip ]; then
        # Removing an already absent owned SO is harmless on subsequent boots.
        PATH="$WORK/mockbin:$PATH" sh "$MOD/$ENTRY" > "$MOD/runtime/output" 2>&1 ||
            fail 'repeated skipped dispatch failed'
        [ ! -e "$MOD/runtime/private.trace" ] || fail 'repeated skipped dispatch ran private'
        [ ! -e "$MOD/system/odm/lib64/libpwirisservicei7p.so" ] ||
            fail 'repeated skipped dispatch recreated its staged SO'
    fi
    echo "PASS: $ENTRY/$SCENARIO"
}

for ENTRY in post-fs-data.sh late-load.sh; do
    sh -n "$ROOT/$ENTRY"
    for SCENARIO in valid private_failure remove skip missing_gate missing_private \
            gate_source_failure missing_gate_function; do
        run_case "$ENTRY" "$SCENARIO"
    done
done
run_case post-fs-data.sh missing_display

echo 'premium boot staging cleanup checks passed'
