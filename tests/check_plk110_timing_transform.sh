#!/bin/sh
# Offline check of the PLK110 timing-node transformation performed by
# src/process_dts.c.
#
# Why this test exists: the rate-injection loop used to start at index 1, which
# turned rate[0] into an undocumented placeholder. Every list whose first entry
# was not 123 produced no overclock node at all, and the only way that was found
# was a four-way experiment on a real device - where one wrong build means a
# device that does not boot. process_dts has a PROCESS_DTS_TEST_MODEL hook and
# only needs a stub <sys/system_properties.h> to build on a normal Linux host, so
# the transformation is testable without a phone.
#
# What it asserts (against a synthetic stock DTS, not a vendor image):
#   * the 90Hz / 120Hz / oplus_fhd_120 fallback timings are ALWAYS removed, with
#     or without an overclock list - the global refresh-rate table must not be
#     able to fall back to 120 or 90, so the panel rests on the 165Hz node;
#   * an empty list therefore removes the fallbacks and adds nothing;
#   * a single-rate list adds exactly that one node, which is what makes a
#     single-variable experiment meaningful;
#   * a list whose first entry is 123 additionally relabels the stock 120Hz node
#     as the 123Hz mode (keeping the vendor timings) instead of dropping it;
#   * a rate already present in the stock tree is never generated twice.
#
# The rate list's ONLY other effect on the transformation is "which extra
# timings to generate" - it must never change whether the fallbacks are removed.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/src/process_dts.c"
CC=${CC:-cc}

[ -f "$SRC" ] || { echo "FAIL: missing $SRC" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler ($CC)" >&2; exit 0; }

WORK=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/mcp_pdts_$$")
mkdir -p "$WORK/inc/sys" "$WORK/dtbo_dts" "$WORK/config"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/inc/sys/system_properties.h" <<'EOF'
/* Host stub. With PROCESS_DTS_TEST_MODEL defined, detect_device_model() takes
 * the test branch and never calls the real property API. */
#ifndef MCP_STUB_SYSTEM_PROPERTIES_H
#define MCP_STUB_SYSTEM_PROPERTIES_H
#define PROP_VALUE_MAX 92
int __system_property_get(const char *name, char *value);
#endif
EOF

# A synthetic PLK110-style stock tree: six timings on the target panel, in the
# same order the vendor DTBO uses. Names only - the transformation under test is
# name/structure driven, so property payloads are unnecessary.
cat > "$WORK/dtbo_dts/dtb_temp.0.dts" <<'EOF'
/dts-v1/;
/ {
	fragment@245 {
		__overlay__ {
			qcom,mdss_dsi_panel_AD296_P_3_A0020_dsc_cmd {
				qcom,mdss-dsi-display-timings {
					timing@sdc_fhd_120 {
						qcom,mdss-dsi-panel-framerate = <0x78>;
					};
					timing@sdc_fhd_90 {
						qcom,mdss-dsi-panel-framerate = <0x5a>;
					};
					timing@sdc_fhd_60 {
						qcom,mdss-dsi-panel-framerate = <0x3c>;
					};
					timing@sdc_fhd_144 {
						qcom,mdss-dsi-panel-framerate = <0x90>;
					};
					timing@sdc_fhd_165 {
						qcom,mdss-dsi-panel-framerate = <0xa5>;
					};
					timing@oplus_fhd_120 {
						qcom,mdss-dsi-panel-framerate = <0x78>;
					};
				};
			};
		};
	};
	oplus,project-id = <0x60ff>;
};
EOF

manifest() {
    cat > "$WORK/config/display_mode_manifest.txt" <<EOF
manifest_version=1
rmx5200_width=1440
rmx5200_height=3136
rmx5200_dtbo_rates=123,150,155,160,165,170,175,180
plk110_width=1272
plk110_height=2772
plk110_dtbo_rates=$1
plq110_width=1272
plq110_height=2772
plq110_dtbo_rates=123,170,175,180,185,190,195,199
pjd110_dtbo_rates=
EOF
}

COUNT="$WORK/count.sh"
cat > "$COUNT" <<'EOF'
#!/bin/sh
# usage: count.sh <dts> <node-name>  -> number of timing@<name> blocks
grep -c "timing@$2[[:space:]]*{" "$1" 2>/dev/null || true
EOF
chmod +x "$COUNT"

run_case() {
    manifest="$1"
    manifest "$manifest"

    # restore the pristine stock file for each case
    cp "$WORK/dtbo_dts/dtb_temp.0.dts.stock" "$WORK/dtbo_dts/dtb_temp.0.dts"
    ( cd "$WORK" && ./process_dts > "$WORK/out.log" 2>&1 ) || {
        echo "FAIL: process_dts exited non-zero for rates='$manifest'" >&2
        tail -20 "$WORK/out.log" >&2
        exit 1
    }
    RESULT="$WORK/dtbo_dts/dtb_temp.0.dts"
}

cp "$WORK/dtbo_dts/dtb_temp.0.dts" "$WORK/dtbo_dts/dtb_temp.0.dts.stock"

"$CC" -O1 -w -I"$WORK/inc" \
    -DPROCESS_DTS_TEST_MODEL=2 \
    -DPROCESS_DTS_TEST_PROJECT_ID=0x60ff \
    -o "$WORK/process_dts" "$SRC"

# --- case 1: empty list -> fallbacks removed, nothing added ---
run_case ""
[ "$("$COUNT" "$RESULT" sdc_fhd_120)" = "0" ] || {
    echo "FAIL: the 120Hz fallback must be removed even with an empty rate list" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" sdc_fhd_90)" = "0" ] || {
    echo "FAIL: the 90Hz fallback must be removed even with an empty rate list" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" oplus_fhd_120)" = "0" ] || {
    echo "FAIL: oplus_fhd_120 must be removed even with an empty rate list" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" sdc_fhd_165)" = "1" ] || {
    echo "FAIL: the 165Hz node must survive" >&2; exit 1; }
for r in 123 170 175 180 185 190 195 199; do
    [ "$("$COUNT" "$RESULT" "sdc_fhd_$r")" = "0" ] || {
        echo "FAIL: empty list generated timing@sdc_fhd_$r" >&2; exit 1; }
done

# --- case 2: single rate -> exactly one new node on top of the fallback removal ---
run_case "170"
[ "$("$COUNT" "$RESULT" sdc_fhd_170)" = "1" ] || {
    echo "FAIL: single-rate list did not generate timing@sdc_fhd_170" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" sdc_fhd_120)" = "0" ] || {
    echo "FAIL: single-rate list must still remove the 120Hz fallback" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" sdc_fhd_90)" = "0" ] || {
    echo "FAIL: single-rate list must still remove the 90Hz fallback" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" sdc_fhd_123)" = "0" ] || {
    echo "FAIL: single-rate list invented a 123Hz node" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" sdc_fhd_199)" = "0" ] || {
    echo "FAIL: single-rate list generated an unlisted rate" >&2; exit 1; }

# --- case 3: a rate already in the stock tree is never generated twice ---
run_case "144"
[ "$("$COUNT" "$RESULT" sdc_fhd_144)" = "1" ] || {
    echo "FAIL: existing stock rate was duplicated" >&2; exit 1; }

# --- case 4: a list starting at 123 relabels the 120Hz node instead of dropping it ---
run_case "123,170"
[ "$("$COUNT" "$RESULT" sdc_fhd_123)" = "1" ] || {
    echo "FAIL: 123 slot replacement missing" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" sdc_fhd_120)" = "0" ] || {
    echo "FAIL: a 120Hz node survived" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" sdc_fhd_170)" = "1" ] || {
    echo "FAIL: 170 missing alongside the slot rate" >&2; exit 1; }
[ "$("$COUNT" "$RESULT" sdc_fhd_90)" = "0" ] || {
    echo "FAIL: 90Hz fallback survived" >&2; exit 1; }

echo "PASS: PLK110 timing transformation honours 0/1/N rate lists"
