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
require_text "$JS" 'runAfterFirstPaint(scheduleModuleInitialization);'
require_text "$JS" 'function scheduleModuleInitialization()'
require_text "$JS" '})().finally(() => {'
require_text "$JS" 'function scheduleTabBackgroundWork(targetId)'
require_text "$JS" 'Mine renders the latest cached authorization snapshot.'
require_text "$JS" "if (activeTabId !== 'tab-oc') {"
require_text "$JS" 'Non-overview pages must remain interaction-only.'
require_text "$JS" "activeTabId !== 'tab-oc' || document.hidden"
require_text "$JS" 'automaticUpdateCheckTimer'
require_text "$JS" 'shouldContinue: () => generation === automaticUpdateCheckGeneration'
require_text "$JS" 'authorizationRefreshGeneration++'
require_text "$JS" 'const canContinue = () => refreshGeneration === authorizationRefreshGeneration'
require_text "$JS" 'tabPageFrame = requestAnimationFrame(() => {'
require_text "$JS" 'displayedTabId = targetId;'
require_text "$JS" "listEl?.dataset.fullListRendered !== '1'"
require_text "$JS" "listEl.dataset.fullListRendered = fullList ? '1' : '0';"
require_text "$JS" 'await ensureAppListLoaded({ renderRates: true });'
require_text "$JS" 'await ensureAppListLoaded({ renderRates: false });'
require_text "$JS" 'if (videoPageRenderKey === renderKey) return;'
require_text "$JS" 'function applyVideoMotionConfig(result)'
require_text "$JS" "setVideoMotionStatus('读取较慢');"
require_text "$JS" "parseGameAssistantConfig(gameAssistantConfigResult, '');"
require_text "$JS" 'function scheduleAppLabelEnrichment(packages)'
require_text "$JS" 'function requestPackageInfoBatch(packages, shouldContinue)'
require_text "$JS" 'ksu.getPackagesInfo(JSON.stringify(packages))'
require_text "$JS" 'if (shouldContinue && !shouldContinue()) {'
require_text "$JS" 'const batch = appLabelEnrichmentPackages.slice();'
require_text "$JS" 'appLabelEnrichmentTimer = setTimeout(start, 600);'
if grep -Eq 'get_app_labels|function enrichAppLabels\(|processLabelQueue|queueAppLabelFetch' "$JS"; then
    echo 'WebUI must not use root label scans or the old label queue' >&2
    exit 1
fi
require_text "$JS" 'if (!force && minePageRenderKey === renderKey'
require_text "$JS" 'requestIdleCallback(task, { timeout: 350 });'
require_text "$CSS" 'content-visibility: auto;'
require_text "$CSS" 'contain: paint;'
require_text "$HOOK" 'getMethod("setTranslucent", boolean.class)'
require_text "$HOOK" 'resolveCommitDurationMillis'
require_text "$HOOK" 'postDelayed'
require_text "$HOOK" 'activity.finish();'

card_css="$(sed -n '/^\.card {/,/^}/p' "$CSS")"
if printf '%s\n' "$card_css" | grep -Eq 'backdrop-filter|-webkit-backdrop-filter|animation:'; then
    echo 'ordinary cards must not create blur or entry animation layers' >&2
    exit 1
fi

bottom_nav_js="$(sed -n '/^function setupBottomNavIndicator()/,/^}/p' "$JS")"
if printf '%s\n' "$bottom_nav_js" | grep -Eq 'pointer(down|move|up)|setPointerCapture|getBoundingClientRect'; then
    echo 'bottom navigation must keep ordinary taps on the lightweight click path' >&2
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
