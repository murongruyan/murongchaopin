#!/usr/bin/env bash
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CSS="$ROOT/webroot/css/style.css"
JS="$ROOT/webroot/js/main.js"
HOOK="$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/KernelSuWebUiHooks.java"

require_text() {
    file="$1"
    text="$2"
    grep -Fq "$text" "$file" || {
        echo "missing WebUI performance contract: $text" >&2
        exit 1
    }
}

require_text "$CSS" 'background-image: none;'
require_text "$CSS" 'Page-level transforms force every glass/backdrop-filter surface'
require_text "$JS" 'function runAfterFirstPaint(task)'
require_text "$JS" 'runAfterFirstPaint(initializeModuleData);'
require_text "$JS" '})().finally(() => {'
require_text "$HOOK" 'getMethod("setTranslucent", boolean.class)'
require_text "$HOOK" 'resolveCommitDurationMillis'
require_text "$HOOK" 'postDelayed'
require_text "$HOOK" 'activity.finish();'

card_css="$(sed -n '/^\.card {/,/^}/p' "$CSS")"
if printf '%s\n' "$card_css" | grep -Eq 'backdrop-filter|-webkit-backdrop-filter|animation:'; then
    echo 'ordinary cards must not create blur or entry animation layers' >&2
    exit 1
fi

if grep -Fq 'finishAfterTransition()' "$HOOK"; then
    echo 'KernelSU WebUI must not wait for the host activity transition' >&2
    exit 1
fi

if grep -Eq 'setWindowAnimations\(0\)|overridePendingTransition\(0, 0\)' "$HOOK"; then
    echo 'KernelSU WebUI must not erase its predictive-back settle animation' >&2
    exit 1
fi

echo 'WebUI performance contracts passed'
