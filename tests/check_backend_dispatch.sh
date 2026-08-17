#!/bin/sh

set -eu

CUSTOMIZE="${1:-customize.sh}"
HANDLER="${2:-scripts/web_handler.sh}"

[ -f "$CUSTOMIZE" ] || { echo "FAIL: missing customize script" >&2; exit 1; }
[ -f "$HANDLER" ] || { echo "FAIL: missing Web handler" >&2; exit 1; }

# Both scripts must parse with the Android shell grammar.
sh -n "$CUSTOMIZE"
sh -n "$HANDLER"

# Installation must expose an explicit selection and persist it.
grep -q 'Install_backend_selection' "$CUSTOMIZE"
grep -q 'MURONGCHAOPIN_INSTALL_BACKEND' "$CUSTOMIZE"
grep -q 'dts_backend.txt' "$CUSTOMIZE"
grep -q 'if \[ "\$INSTALL_BACKEND" = "dtbo" \]; then' "$CUSTOMIZE"
grep -q '已选择 DRM-KO：高刷 timing 仅由 KO 注入' "$CUSTOMIZE"
grep -q 'ui_print "请选择首次应用后端:" >&2' "$CUSTOMIZE"
grep -q 'dtbo|drm) ;;' "$CUSTOMIZE"
grep -q 'timeout 1 getevent -qlc 1' "$CUSTOMIZE"

# Install_backend_selection is called through command substitution. Prompts
# must never pollute the single-line value persisted to dts_backend.txt.
if grep -q 'ui_print "请选择首次应用后端:"$' "$CUSTOMIZE"; then
    echo "FAIL: backend prompt is still written to captured stdout" >&2
    exit 1
fi

# The only install-time partition write must be inside the DTBO branch.
[ "$(grep -c 'dtbo_write_partition' "$CUSTOMIZE")" -eq 1 ] || {
    echo "FAIL: customize.sh has an unexpected number of DTBO writes" >&2
    exit 1
}

# Both synchronous and background Web flash commands must dispatch through the
# selected backend after workspace editing; neither may hard-code DTBO stages.
grep -q 'do_apply_selected_backend()' "$HANDLER"
grep -q 'do_smart_add "\$2" && do_apply_selected_backend' "$HANDLER"
grep -q 'do_apply_selected_backend || FLASH_RESULT=\$?' "$HANDLER"
if grep -q 'do_smart_add "\$2" && do_pack' "$HANDLER"; then
    echo "FAIL: Web flash path still hard-codes DTBO packing" >&2
    exit 1
fi

grep -q 'do_ko_prepare' "$HANDLER"
grep -q 'planned_backend=drm' "$HANDLER"
# 旧版 UI 曾提供 Overlay/auto 后端选项；MEMC overlay 等正常文案不在其列。
if grep -qE 'overlay[_-]?backend|Overlay[_-]?backend|backend.*auto|auto.*backend|btn-backend-ko' "$HANDLER" "$CUSTOMIZE"; then
    echo "FAIL: legacy Overlay/auto backend remains" >&2
    exit 1
fi

echo "PASS: install and Web flash backend dispatch is selectable"
