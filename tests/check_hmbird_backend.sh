#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

mkdir -p "$TMP_DIR/scripts" "$TMP_DIR/config" "$TMP_DIR/bin" \
    "$TMP_DIR/fakebin" "$TMP_DIR/sys/module" "$TMP_DIR/state"
cp "$ROOT/scripts/hmbird_backend.sh" "$TMP_DIR/scripts/hmbird_backend.sh"
touch "$TMP_DIR/bin/hmbird.ko"

cat > "$TMP_DIR/fakebin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
    ro.soc.model) printf '%s\n' "${HMBIRD_TEST_SOC:-SM8850}" ;;
    ro.build.version.realmeui)
        [ "${HMBIRD_TEST_UI:-realmeui}" = realmeui ] && printf '%s\n' V7.0 ;;
    ro.product.brand|ro.product.manufacturer)
        case "${HMBIRD_TEST_UI:-realmeui}" in
            realmeui) printf '%s\n' realme ;;
            coloros) printf '%s\n' oppo ;;
        esac ;;
    ro.build.version.oplusrom)
        [ "${HMBIRD_TEST_UI:-realmeui}" = coloros ] && printf '%s\n' V16.1.0 ;;
esac
EOF
chmod +x "$TMP_DIR/fakebin/getprop"

cat > "$TMP_DIR/fakebin/insmod" <<'EOF'
#!/bin/sh
type=
dynamic=
for arg in "$@"; do
    case "$arg" in
        hmbird_type=*) type=${arg#*=} ;;
        dynamic_of=*) dynamic=${arg#*=} ;;
    esac
done
printf '%s\n' "$*" > "$HMBIRD_TEST_INSMOD_LOG"
mkdir -p "$HMBIRD_SYS_MODULE_ROOT/hmbird/parameters"
printf 'Y\n' > "$HMBIRD_SYS_MODULE_ROOT/hmbird/parameters/node_present"
printf 'N\n' > "$HMBIRD_SYS_MODULE_ROOT/hmbird/parameters/node_created"
printf 'N\n' > "$HMBIRD_SYS_MODULE_ROOT/hmbird/parameters/consumer_reinit_supported"
printf '%s\n' "$type" > "$HMBIRD_SYS_MODULE_ROOT/hmbird/parameters/selected_type"
printf '0\n' > "$HMBIRD_SYS_MODULE_ROOT/hmbird/parameters/failure_code"
printf '%s\n' "$dynamic" > "$HMBIRD_TEST_DYNAMIC_VALUE"
EOF
chmod +x "$TMP_DIR/fakebin/insmod"

run_helper() {
    PATH="$TMP_DIR/fakebin:$PATH" \
    HMBIRD_SYS_MODULE_ROOT="$TMP_DIR/sys/module" \
    HMBIRD_TEST_INSMOD_LOG="$TMP_DIR/state/insmod.log" \
    HMBIRD_TEST_DYNAMIC_VALUE="$TMP_DIR/state/dynamic_of" \
    HMBIRD_TEST_UI="$1" HMBIRD_TEST_SOC="$2" \
        sh "$TMP_DIR/scripts/hmbird_backend.sh" apply
}

assert_case() {
    ui=$1
    soc=$2
    expected=$3
    rm -rf "$TMP_DIR/sys/module/hmbird"
    rm -f "$TMP_DIR/state/insmod.log" "$TMP_DIR/state/dynamic_of"
    run_helper "$ui" "$soc"
    grep -q "^applied:node_present=Y,node_created=N,type=$expected,consumer_reinit=N$" \
        "$TMP_DIR/runtime/hmbird/status.txt"
    grep -q "hmbird_type=$expected" "$TMP_DIR/state/insmod.log"
    grep -q 'dynamic_of=0' "$TMP_DIR/state/insmod.log"
}

for pair in \
    'SM8850 HMBIRD_EXT' 'SM8850P HMBIRD_EXT' 'SM8845 HMBIRD_EXT' \
    'SM8750 HMBIRD_OGKI' 'SM8750P HMBIRD_OGKI' 'SM8650 HMBIRD_OGKI' \
    'SM8650P HMBIRD_OGKI' 'MT6991 HMBIRD_OGKI' 'MT6993 HMBIRD_OGKI'; do
    set -- $pair
    assert_case realmeui "$1" "$2"
done
assert_case coloros SM8750 HMBIRD_OGKI

rm -rf "$TMP_DIR/sys/module/hmbird"
rm -f "$TMP_DIR/state/insmod.log"
run_helper realmeui SM9999
grep -q '^unsupported:soc_model$' "$TMP_DIR/runtime/hmbird/status.txt"
[ ! -e "$TMP_DIR/state/insmod.log" ]

rm -rf "$TMP_DIR/sys/module/hmbird"
rm -f "$TMP_DIR/state/insmod.log"
run_helper other SM8850
grep -q '^unsupported:ui_family$' "$TMP_DIR/runtime/hmbird/status.txt"
[ ! -e "$TMP_DIR/state/insmod.log" ]

# Backend selection and legacy DRM tokens must not gate the free component.
printf '%s\n' dtbo > "$TMP_DIR/config/dts_backend.txt"
rm -rf "$TMP_DIR/sys/module/hmbird"
rm -f "$TMP_DIR/state/insmod.log"
run_helper realmeui SM8850
grep -q '^applied:node_present=Y,node_created=N,type=HMBIRD_EXT,consumer_reinit=N$' \
    "$TMP_DIR/runtime/hmbird/status.txt"
grep -q 'hmbird_type=HMBIRD_EXT' "$TMP_DIR/state/insmod.log"

# A pre-existing module must still expose matching gate results.  Merely
# sharing the module name is not enough to bypass current UI/SoC/type checks.
mkdir -p "$TMP_DIR/sys/module/hmbird/parameters"
printf '0\n' > "$TMP_DIR/sys/module/hmbird/parameters/ui_valid"
printf '1\n' > "$TMP_DIR/sys/module/hmbird/parameters/soc_valid"
printf '1\n' > "$TMP_DIR/sys/module/hmbird/parameters/type_valid"
printf '1\n' > "$TMP_DIR/sys/module/hmbird/parameters/node_present"
printf 'HMBIRD_EXT\n' > "$TMP_DIR/sys/module/hmbird/parameters/selected_type"
printf '0\n' > "$TMP_DIR/sys/module/hmbird/parameters/failure_code"
rm -f "$TMP_DIR/state/insmod.log"
run_helper realmeui SM8850
grep -q '^blocked:existing_module_mismatch$' "$TMP_DIR/runtime/hmbird/status.txt"
[ ! -e "$TMP_DIR/state/insmod.log" ]

grep -q 'SM8850' "$ROOT/src/ko/hmbird.c"
grep -q 'SM8850P' "$ROOT/src/ko/hmbird.c"
grep -q 'SM8845' "$ROOT/src/ko/hmbird.c"
grep -q 'HMBIRD_EXT' "$ROOT/src/ko/hmbird.c"
grep -q 'SM8750' "$ROOT/src/ko/hmbird.c"
grep -q 'SM8750P' "$ROOT/src/ko/hmbird.c"
grep -q 'SM8650' "$ROOT/src/ko/hmbird.c"
grep -q 'SM8650P' "$ROOT/src/ko/hmbird.c"
grep -q 'MT6991' "$ROOT/src/ko/hmbird.c"
grep -q 'MT6993' "$ROOT/src/ko/hmbird.c"
grep -q 'HMBIRD_OGKI' "$ROOT/src/ko/hmbird.c"
grep -q 'dynamic_of=' "$ROOT/scripts/hmbird_backend.sh"

! grep -q 'drm_experimental_enable\|dts_backend.txt' "$ROOT/scripts/hmbird_backend.sh"

echo "PASS: free HMBIRD gates UI/SoC/type and loads independently of the display backend"
