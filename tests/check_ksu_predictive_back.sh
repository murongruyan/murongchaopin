#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOOK="$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/KernelSuWebUiHooks.java"
ENTRY="$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/DisplaySettingsHook.java"
SCOPE="$ROOT/src/settings_hook/resources-free/META-INF/xposed/scope.list"
JS="$ROOT/webroot/js/main.js"
CSS="$ROOT/webroot/css/style.css"

[ -f "$HOOK" ] || { echo "FAIL: missing KernelSU WebUI hook" >&2; exit 1; }
grep -q 'me.weishu.kernelsu.ui.webui.WebUIActivity' "$HOOK"
grep -q 'OnBackAnimationCallback' "$HOOK"
grep -q 'PRIORITY_OVERLAY' "$HOOK"
grep -q 'target.goBack()' "$HOOK"
grep -q 'dispatch(target, "commit"' "$HOOK"
grep -q 'resolveCommitDurationMillis' "$HOOK"
grep -q 'postDelayed' "$HOOK"
grep -q 'queryCanPop' "$HOOK"
grep -q 'setActivityTranslucent(module, activity, true)' "$HOOK"
grep -q 'convertFromTranslucent' "$HOOK"
if grep -q 'overridePendingTransition(0, 0)' "$HOOK"; then
    echo 'FAIL: host zero-transition override masks the predictive-back settle' >&2
    exit 1
fi
grep -q 'KernelSuWebUiHooks.install' "$ENTRY"
grep -qx 'me.weishu.kernelsu' "$SCOPE"
grep -q 'window.__murongPredictiveBack' "$JS"
grep -q 'tabHistory' "$JS"
grep -q '__murongPredictiveBackCanPop' "$JS"
grep -q 'predictive-back-layer' "$JS"
grep -q 'predictive-back-from' "$CSS"
grep -q 'predictive-back-to' "$CSS"
grep -q 'bottom-nav::before' "$CSS"
grep -q -- '--tab-indicator-index' "$CSS"
grep -q 'predictive-back-root-active' "$CSS"
if grep -q 'startViewTransition' "$JS" || grep -q 'view-transition-name' "$CSS"; then
    echo 'FAIL: heavyweight WebView snapshot transition reintroduced' >&2
    exit 1
fi
if sed -n '/@keyframes pageForwardIn/,/^}/p; /@keyframes pageBackIn/,/^}/p' "$CSS" | grep -q 'opacity'; then
    echo 'FAIL: page navigation must not leave a translucent snapshot' >&2
    exit 1
fi

if command -v node >/dev/null 2>&1; then
    node --check "$JS"
fi
echo "PASS: KernelSU WebUI predictive-back progress bridge preserves WebView history semantics"
