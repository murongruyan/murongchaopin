#!/bin/sh

set -eu

SOURCE="${1:-src/process_dts.c}"
BINARY="${2:-bin/process_dts}"

[ -f "$SOURCE" ] || { echo "FAIL: missing process_dts source" >&2; exit 1; }
[ -f "$BINARY" ] || { echo "FAIL: missing process_dts binary" >&2; exit 1; }

# Low-refresh nodes must be emitted from the input block. High-refresh
# templates are reserved for newly appended modes and must never replace the
# vendor's LTPS/ADFR fallback timings.
grep -q 'strstr(node_name, "wqhd_sdc_60")' "$SOURCE"
grep -q 'strstr(node_name, "wqhd_sdc_90")' "$SOURCE"
grep -q 'fputs(current_block, out);' "$SOURCE"
grep -q 'strstr(node_name, "timing@sdc_fhd_60")' "$SOURCE"

if grep -qE 'Applying LTPO|Replacing 60Hz|Force WQHD 90|template_sdc_165\.content' "$SOURCE"; then
    echo "FAIL: high-refresh template replacement leaked into low-refresh path" >&2
    exit 1
fi

echo "PASS: stock low-refresh timing preservation is enforced"
