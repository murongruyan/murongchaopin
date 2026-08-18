#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HANDLER="$ROOT/scripts/web_handler.sh"
HTML="$ROOT/webroot/index.html"
JS="$ROOT/webroot/js/main.js"
COLOROS="$ROOT/scripts/coloros_config.sh"

sh -n "$HANDLER"
sh -n "$COLOROS"

grep -q 'id="tab-video"' "$HTML"
grep -q 'id="video-motion-target"' "$HTML"
grep -q 'id="video-app-activity"' "$HTML"
grep -q 'id="video-app-picker" class="form-input selection-trigger"' "$HTML"
grep -q 'id="video-app-rate" class="form-input selection-trigger"' "$HTML"
grep -q '>插帧刷新率</label>' "$HTML"
grep -q 'R1 原生' "$HTML"
grep -q 'get_video_motion_config' "$HANDLER"
grep -q 'set_video_motion_target' "$HANDLER"
grep -q 'add_video_motion_app' "$HANDLER"
grep -q 'remove_video_motion_app' "$HANDLER"
grep -q 'get_foreground_activity' "$HANDLER"
grep -q 'VIDEO_MEMC_APPS_FILE' "$HANDLER"
grep -q 'nativeMemcRates = new Set(\[60, 90, 120, 144\])' "$JS"
grep -q 'R1 扩展输出路径' "$JS"
grep -q "return '跟随用户选择'" "$JS"
grep -q 'return `优化至 \${rate} 帧`' "$JS"
grep -q 'mode.width === currentResolutionWidth' "$JS"
grep -q 'loadVideoMotionConfig();' "$JS"
grep -q 'loadVideoMotionApps' "$JS"
grep -q 'readForegroundVideoActivity' "$JS"
grep -q 'openVideoAppPicker' "$JS"
grep -q 'openVideoRatePicker' "$JS"
grep -q 'videoRateOptions' "$JS"
grep -q "safeBind('video-app-picker', 'onclick'" "$JS"
grep -q "safeBind('video-app-rate', 'onclick'" "$JS"
grep -q 'rate >= 30 && rate <= 1000' "$JS"
grep -q 'shellQuote' "$JS"
grep -q 'MEMC refresh rate must be 30-1000Hz' "$HANDLER"
if grep -q 'vendor rate must be 60 or 120\|厂商档' "$HANDLER" "$HTML" "$JS"; then
    echo 'FAIL: video app refresh rate is still exposed as a 60/120 vendor preset' >&2
    exit 1
fi

if grep -q 'write_global_config\|write_resolution_config\|write_app_config' "$HANDLER"; then
    : # Existing display commands own durable mode.txt writes; video commands are checked below.
fi
VIDEO_CASES=$(sed -n '/"get_video_motion_config")/,/"init_workspace")/p' "$HANDLER")
if printf '%s\n' "$VIDEO_CASES" | grep -q 'CONFIG_FILE'; then
    echo 'FAIL: video Web commands modify mode.txt' >&2
    exit 1
fi

echo 'PASS: WebUI exposes validated Pixelworks MEMC policy and app whitelist controls'
