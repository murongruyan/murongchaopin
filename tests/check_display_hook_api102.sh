#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOOK_ROOT="$ROOT/src/settings_hook"
ENTRY="$HOOK_ROOT/java/com/murongchaopin/displayhook/DisplaySettingsHook.java"
PREMIUM_ENTRY="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/PremiumDisplayHook.java"
GAME="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/GameAssistantHooks.java"
SCENE="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/SceneHooks.java"
SERVICES="$HOOK_ROOT/java/com/murongchaopin/displayhook/OplusServicesHooks.java"
PREMIUM_SERVICES="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/PremiumServiceHooks.java"
RESOLVER="$HOOK_ROOT/java/com/murongchaopin/displayhook/FrameworkModeResolverHooks.java"
ENVELOPE="$HOOK_ROOT/java/com/murongchaopin/displayhook/FrameworkPhysicalEnvelopeHooks.java"
LTPS="$HOOK_ROOT/java/com/murongchaopin/displayhook/OplusLtpsModeHooks.java"
FRONT="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/SettingsFrontPageHooks.java"
RESOLUTION="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/SettingsResolutionHooks.java"
SETTINGS_UI="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/SettingsHooks.java"
VIDEO="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/VideoMotionHooks.java"
VIDEO_POLICY="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/VideoMotionPolicy.java"
VIDEO_SERVICE="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/VideoMotionServiceHooks.java"
COLOROS_PLAYER="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/ColorosVideoPlaybackHooks.java"
BILIBILI_STORY="$HOOK_ROOT/java/com/murongchaopin/displayhook/BilibiliStoryHooks.java"
BRIDGE="$HOOK_ROOT/java/com/murongchaopin/displayhook/BridgeClient.java"
NOTIFICATION_LTPO="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/NotificationLtpoHooks.java"
FREE_GATE="$HOOK_ROOT/java-free/com/murongchaopin/displayhook/PremiumGateBridge.java"
PREMIUM_GATE="$HOOK_ROOT/java-premium/com/murongchaopin/displayhook/PremiumGateBridge.java"
FREE_META="$HOOK_ROOT/resources-free/META-INF/xposed"
PREMIUM_META="$HOOK_ROOT/resources-premium/META-INF/xposed"

test -f "$HOOK_ROOT/build.gradle.kts"
grep -q 'io.github.libxposed:api:102.0.0' "$HOOK_ROOT/build.gradle.kts"
grep -q 'applicationIdSuffix = ".premium"' "$HOOK_ROOT/build.gradle.kts"
grep -q 'java.directories.add("java-free")' "$HOOK_ROOT/build.gradle.kts"
grep -q 'java.directories.add("java-premium")' "$HOOK_ROOT/build.gradle.kts"
grep -q 'res.directories.add("res-free")' "$HOOK_ROOT/build.gradle.kts"
grep -q 'res.directories.add("res-premium")' "$HOOK_ROOT/build.gradle.kts"
grep -q 'exclude("\*\*/BilibiliStoryHooks.java")' "$HOOK_ROOT/build.gradle.kts"
grep -q 'extends XposedModule' "$ENTRY"
grep -q 'extends DisplaySettingsHook' "$PREMIUM_ENTRY"
grep -q 'onPackageReady' "$ENTRY"
grep -q 'onSystemServerStarting' "$ENTRY"
grep -q 'SystemServerStartingParam' "$ENTRY"
grep -q '"system".equals(processName)' "$ENTRY"
grep -q 'SYSTEM.equals(packageName)' "$ENTRY"
grep -q 'system package ready=' "$ENTRY"
grep -q '^minApiVersion=102$' "$FREE_META/module.prop"
grep -q '^targetApiVersion=102$' "$FREE_META/module.prop"
grep -q '^staticScope=true$' "$FREE_META/module.prop"
grep -q '^system$' "$FREE_META/scope.list"
grep -q '^me.weishu.kernelsu$' "$FREE_META/scope.list"
grep -q '^com.murongchaopin.displayhook.DisplaySettingsHook$' \
    "$FREE_META/java_init.list"
grep -q '^minApiVersion=102$' "$PREMIUM_META/module.prop"
grep -q '^targetApiVersion=102$' "$PREMIUM_META/module.prop"
grep -q '^staticScope=true$' "$PREMIUM_META/module.prop"
grep -q '^system$' "$PREMIUM_META/scope.list"
grep -q '^com.android.settings$' "$PREMIUM_META/scope.list"
grep -q '^com.oplus.games$' "$PREMIUM_META/scope.list"
grep -q '^com.omarea.vtools$' "$PREMIUM_META/scope.list"
grep -q '^com.coloros.video$' "$PREMIUM_META/scope.list"
grep -q '^com.murongchaopin.displayhook.PremiumDisplayHook$' \
    "$PREMIUM_META/java_init.list"
if grep -qE '^(com\.android\.settings|com\.oplus\.games|com\.omarea\.vtools|com\.coloros\.video|tv\.danmaku\.bili)$' "$FREE_META/scope.list"; then
    echo 'FAIL: paid UI scope leaked into the free Hook' >&2
    exit 1
fi
if grep -qE '^(me\.weishu\.kernelsu|tv\.danmaku\.bili)$' \
        "$PREMIUM_META/scope.list"; then
    echo 'FAIL: free or stopped scope leaked into the premium Hook' >&2
    exit 1
fi
grep -q 'SettingsHooks.install' "$PREMIUM_ENTRY"
grep -q 'SettingsFrontPageHooks.install' "$PREMIUM_ENTRY"
grep -q 'SettingsResolutionHooks.install' "$PREMIUM_ENTRY"
grep -q 'GameAssistantHooks.install' "$PREMIUM_ENTRY"
grep -q 'SceneHooks.install' "$PREMIUM_ENTRY"
if grep -qE 'SettingsHooks\.install|SettingsFrontPageHooks\.install|SettingsResolutionHooks\.install|GameAssistantHooks\.install|SceneHooks\.install' "$ENTRY"; then
    echo 'FAIL: paid display UI dispatcher leaked into the free entry point' >&2
    exit 1
fi
grep -q '慕容显示增强（基础组件）' "$HOOK_ROOT/res-free/values/strings.xml"
grep -q '慕容显示增强（付费组件）' "$HOOK_ROOT/res-premium/values/strings.xml"
grep -q 'isVendorMemcActive' "$FREE_GATE"
if grep -qE 'isFeatureEnabled|premium_enabled|premium_features' "$FREE_GATE"; then
    echo 'FAIL: signed-lease feature gate leaked into the free Hook' >&2
    exit 1
fi
grep -q 'premium_enabled' "$PREMIUM_GATE"
grep -q 'premium_features' "$PREMIUM_GATE"
grep -q 'isFeatureEnabled' "$PREMIUM_GATE"
grep -q 'sys.murong.premium_enabled' "$PREMIUM_GATE"
grep -q 'sys.murong.premium_features' "$PREMIUM_GATE"
grep -q 'setprop sys.murong.premium_enabled' "$ROOT/post-fs-data.sh"
grep -q 'setprop sys.murong.premium_features' "$ROOT/post-fs-data.sh"

if find "$HOOK_ROOT" -type f \( -name xposed_init -o -path '*/de/robv/*' \) | grep -q .; then
    echo 'FAIL: legacy Xposed API files remain in the API 102 module' >&2
    exit 1
fi
if grep -R -q 'de\.robv\.android\.xposed' "$HOOK_ROOT/java" \
        "$HOOK_ROOT/java-free" "$HOOK_ROOT/java-premium"; then
    echo 'FAIL: API 102 hook still imports legacy Xposed APIs' >&2
    exit 1
fi

grep -q 'PerfDisplayRefreshRateVH' "$GAME"
grep -q 'PerfModeSettingView' "$GAME"
grep -q 'PerfSelectionStateView' "$GAME"
grep -q 'GAME_STATUS_CLASS = "de0.a"' "$GAME"
grep -q 'ROOT_PANEL_CLASS = "a.r02"' "$SCENE"
grep -q 'ADB_PANEL_CLASS = "a.g12"' "$SCENE"
grep -q 'PopupWindow.class.getDeclaredMethods' "$SCENE"
grep -q 'LayoutInflater.class.getDeclaredMethods' "$SCENE"
grep -q 'android.view.WindowManagerImpl' "$SCENE"
grep -q 'Scene hooks installed popup=' "$SCENE"
grep -q 'BridgeClient.setGlobalRate' "$SCENE"
grep -q 'BridgeClient.setAppRate' "$GAME"
grep -q 'OPlusRefreshRateService' "$SERVICES"
grep -q 'handleFrontAppChange' "$SERVICES"
grep -q 'getPreferredFrameRate' "$SERVICES"
grep -q 'setUsrOverrideRefreshRate' "$SERVICES"
grep -q 'BridgeClient.removeAppRate' "$SERVICES"
grep -q 'RATE_CACHE' "$SERVICES"
grep -q 'WORKER.execute' "$SERVICES"
grep -q 'OplusResolutionSwitchImpl' "$SERVICES"
grep -q 'onResolutionSettingsChange' "$SERVICES"
grep -q 'boolean firstInit = Boolean.TRUE.equals(chain.getArg(0))' "$SERVICES"
grep -q 'native-path=proceeded' "$SERVICES"
grep -q 'FrameworkModeResolverHooks.install' "$SERVICES"
grep -q 'FrameworkPhysicalEnvelopeHooks.install' "$SERVICES"
grep -q 'OplusLtpsModeHooks.install' "$SERVICES"
grep -q 'LocalDisplayAdapter\$LocalDisplayDevice' "$RESOLVER"
grep -q 'findMode' "$RESOLVER"
grep -q 'findUserPreferredModeIdLocked' "$RESOLVER"
grep -q 'RATE_EPSILON_HZ = 0.01f' "$RESOLVER"
grep -q 'ro.product.vendor.model' "$RESOLVER"
grep -q '"RMX5200".equalsIgnoreCase' "$RESOLVER"
grep -q 'mode.getModeId() < selected.getModeId()' "$RESOLVER"
grep -q 'candidates=\[' "$RESOLVER"
grep -q 'usesExtendedFhdGroup' "$RESOLVER"
grep -q 'extendedFhdGroup' "$RESOLVER"
grep -q 'getDesiredDisplayModeSpecs' "$ENVELOPE"
grep -q 'mAppSupportedModesByDisplay' "$ENVELOPE"
grep -q 'mVotesStorage' "$ENVELOPE"
grep -q 'setPhysicalRange(specs, "primary"' "$ENVELOPE"
grep -q 'setPhysicalRange(specs, "appRequest"' "$ENVELOPE"
grep -q 'boolean extended = usesExtendedFhdGroup(mode)' "$ENVELOPE"
grep -q 'extended && !selectedExtended' "$ENVELOPE"
grep -q 'debug.tracing.screen_state' "$ENVELOPE"
grep -q 'getFinalDisplayModeIdLocked' "$LTPS"
grep -q 'getPerfectRefreshRate' "$LTPS"
grep -q 'QHD LTPS mode corrected' "$LTPS"
if grep -qE 'PowerManager|isInteractive|getSystemContext|getSystemService' "$ENVELOPE"; then
    echo 'FAIL: physical envelope hook re-enters a system service while DMS is locked' >&2
    exit 1
fi
NATIVE_BODY=$(sed -n '/boolean firstInit = Boolean.TRUE.equals/,/return result;/p' "$SERVICES")
printf '%s\n' "$NATIVE_BODY" | grep -q 'Object result = chain.proceed();'
if printf '%s\n' "$NATIVE_BODY" | grep -q 'return null;'; then
    echo 'FAIL: system_server still suppresses the native ColorOS resolution path' >&2
    exit 1
fi
grep -q 'ScreenRefreshRateFragment' "$FRONT"
grep -q 'murong_refresh_rate_' "$FRONT"
grep -q 'BridgeClient.setGlobalRate' "$FRONT"
grep -q 'SELECTION_DEBOUNCE_MS' "$FRONT"
grep -q 'pendingTask.cancel(false)' "$FRONT"
grep -q 'request("SETGLOBAL " + fps, MODE_TIMEOUT_MS)' \
    "$HOOK_ROOT/java/com/murongchaopin/displayhook/BridgeClient.java"
grep -Eq 'BridgeClient[.:]+setGlobalAuto' "$FRONT"
grep -q 'refreshOtherPref' "$FRONT"
grep -q 'ScreenResolutionFragment' "$RESOLUTION"
grep -q 'handlePreferenceTreeClick' "$RESOLUTION"
grep -q 'BridgeClient.adoptGlobalResolution' "$RESOLUTION"
grep -q 'newMode == 1' "$RESOLUTION"
grep -q 'newMode == previousMode' "$RESOLUTION"
grep -q 'REQUEST_GENERATION' "$RESOLUTION"
grep -q 'sourceWidth, sourceDensity, generation' "$RESOLUTION"
grep -q 'display_density_forced' "$HOOK_ROOT/java/com/murongchaopin/displayhook/BridgeClient.java"
if grep -q 'showOpenLoading' "$RESOLUTION"; then
    echo "FAIL: resolution hook must not create ColorOS snapshot/loading geometry" >&2
    exit 1
fi
if grep -q 'scaledDensity' "$RESOLUTION"; then
    echo "FAIL: resolution hook still derives density from stale DisplayMetrics" >&2
    exit 1
fi
grep -q 'Settings native resolution armed' "$RESOLUTION"
grep -q 'refreshOtherPref' "$RESOLUTION"
grep -q 'unlockMotionRestrictedChoices' "$RESOLUTION"
grep -q '"mQhdPreference"' "$RESOLUTION"
grep -q '"mAutoPreference"' "$RESOLUTION"
grep -q '"mCategory"' "$RESOLUTION"
if grep -qE 'BridgeClient\.(setGlobalResolution|prepareGlobalResolution)' "$RESOLUTION"; then
    echo "FAIL: Settings hook still starts a second geometry transaction" >&2
    exit 1
fi
ADOPT_LINE=$(grep -n 'BridgeClient.adoptGlobalResolution' "$RESOLUTION" | head -n 1 | cut -d: -f1)
PROCEED_LINE=$(grep -n 'Object result = chain.proceed();' "$RESOLUTION" | head -n 1 | cut -d: -f1)
[ "$ADOPT_LINE" -lt "$PROCEED_LINE" ] || {
    echo "FAIL: old DisplayManager preference must be cleared before native Settings geometry" >&2
    exit 1
}
if grep -q 'Settings.Secure.putInt' "$RESOLUTION"; then
    echo "FAIL: Settings must not publish a resolution index before HWC completes" >&2
    exit 1
fi
grep -q 'Iris5MotionFluencySettingsFragment' "$VIDEO"
grep -q 'Iris5MotionFluencyDialogUtils' "$VIDEO"
grep -q 'showIris5MotionFluencyDialog' "$VIDEO"
grep -q 'Iris5SettingsFragment' "$VIDEO"
grep -q 'Iris5MotionFluencyController' "$VIDEO"
grep -q 'setSwitchData' "$VIDEO"
grep -q 'setIris5MotionFluencyValue' "$VIDEO"
grep -q 'VideoMotionPolicy.write' "$VIDEO"
grep -q '跟随用户选择' "$VIDEO"
grep -q 'immediateModeChange=0' "$VIDEO"
grep -q '"onResume".equals(method.getName())' "$VIDEO"
grep -q 'refreshMotionSummary(module, owner)' "$VIDEO"
grep -q 'updateControllerSummary(module, chain.getThisObject())' "$VIDEO"
if grep -q 'BridgeClient.setGlobalMode' "$VIDEO"; then
    echo 'FAIL: selecting a video policy still changes the display immediately' >&2
    exit 1
fi
grep -q 'murong_video_motion_target_rate' "$VIDEO_POLICY"
grep -q 'FOLLOW_USER_SELECTION = 0' "$VIDEO_POLICY"
grep -q 'Settings.Secure.putInt' "$VIDEO_POLICY"
grep -q 'OplusFeatureMEMC' "$VIDEO_SERVICE"
grep -q 'requestScreenRate' "$VIDEO_SERVICE"
grep -q 'updateStateMachine' "$VIDEO_SERVICE"
grep -q 'mIrisMemc' "$VIDEO_SERVICE"
grep -q 'PIXELWORKS_APP_OBSERVER' "$VIDEO_SERVICE"
grep -q 'onActivityEnter' "$VIDEO_SERVICE"
grep -q 'onAppEnter' "$VIDEO_SERVICE"
grep -q 'onActivityExit' "$VIDEO_SERVICE"
grep -q 'onAppExit' "$VIDEO_SERVICE"
grep -q 'GPU_VIDEO_FALLBACK_DELAY_MS' "$VIDEO_SERVICE"
grep -q 'mActivityEnter' "$VIDEO_SERVICE"
grep -q 'mMEMCCmd' "$VIDEO_SERVICE"
grep -q 'checkTopActivity' "$VIDEO_SERVICE"
grep -q 'isPortraitMemcEligible' "$VIDEO_SERVICE"
grep -q 'PORTRAIT_ROTATION_OVERRIDE' "$VIDEO_SERVICE"
grep -q 'scheduleInputTimingPrime' "$VIDEO_SERVICE"
grep -q 'INPUT_TIMING_POLL_DELAY_MS = 200L' "$VIDEO_SERVICE"
grep -q 'INPUT_TIMING_READY_TIMEOUT_MS = 7000L' "$VIDEO_SERVICE"
grep -q 'MEMC_INPUT_MAX_REFRESH_RATE = 60.5f' "$VIDEO_SERVICE"
grep -q 'submitted after input' "$VIDEO_SERVICE"
grep -q 'pending.handler.sendEmptyMessage(MSG_SET_MEMC_PARAMETERS)' "$VIDEO_SERVICE"
grep -q 'Bilibili Story MEMC parameters held until 60Hz input is stable' "$VIDEO_SERVICE"
grep -q 'BILIBILI_STORY_INPUT_RECOVERIES' "$VIDEO_SERVICE"
grep -q 'recycling vendor MEMC session once' "$VIDEO_SERVICE"
if grep -q 'INPUT_TIMING_HANDSHAKE_REPLAY' "$VIDEO_SERVICE"; then
    echo 'FAIL: ineffective Story screen-rate vote replay loop remains' >&2
    exit 1
fi
grep -q 'PENDING_BILIBILI_TRANSIENT_RATE_HOLDS' "$VIDEO_SERVICE"
grep -q 'expireBilibiliTransientRateHold' "$VIDEO_SERVICE"
grep -q 'isBilibiliStoryActivity(owner)' "$VIDEO_SERVICE"
grep -q 'MEMC parameters remain input-gated' "$VIDEO_SERVICE"
grep -q 'scheduleVideoLayerReplay' "$VIDEO_SERVICE"
grep -q 'MSG_SET_ENTER_SCREEN_RATE = 1001' "$VIDEO_SERVICE"
grep -q 'handler.sendEmptyMessage(MSG_SET_ENTER_SCREEN_RATE)' "$VIDEO_SERVICE"
grep -q 'MEMC_PARAMETERS_DELAY_MS = 600L' "$VIDEO_SERVICE"
grep -q 'screen-rate handshake and' "$VIDEO_SERVICE"
if grep -qE 'Reflect\.setField\(owner, "m(IrisMemc|LastIrisMemc)", true\)' "$VIDEO_SERVICE"; then
    echo 'FAIL: MEMC hook still forges vendor state-machine fields' >&2
    exit 1
fi
grep -q 'MSG_SET_MEMC_PARAMETERS = 1003' "$VIDEO_SERVICE"
grep -q 'handler.sendEmptyMessageDelayed(MSG_SET_MEMC_PARAMETERS' "$VIDEO_SERVICE"
grep -q 'Reflect.staticFieldAssignableTo(owner.getClass(), Context.class)' "$VIDEO_SERVICE"
grep -q 'VideoMotionPolicy.memcTarget(target)' "$VIDEO_SERVICE"
grep -q 'VideoMotionPolicy.isDirectR1Rate(selectedTarget)' "$VIDEO_SERVICE"
grep -q 'boolean vendorScreenRate = VideoMotionPolicy.usesVendorScreenRate(selectedTarget);' "$VIDEO_SERVICE"
grep -q 'int outputTarget = directR1' "$VIDEO_SERVICE"
grep -q 'int appliedTarget = vendorScreenRate ? -1 : outputTarget;' "$VIDEO_SERVICE"
grep -q 'BridgeClient.startVideoModeVendorOwned()' "$VIDEO_SERVICE"
grep -q 'VideoMotionPolicy.usesVendorScreenRate(selectedTarget)' "$VIDEO_SERVICE"
grep -q 'vendor-owned' "$VIDEO_SERVICE"
grep -q 'screenTiming=' "$VIDEO_SERVICE"
grep -q 'vendorScreenRate=' "$VIDEO_SERVICE"
grep -q 'BridgeClient.endVideoMode' "$VIDEO_SERVICE"
grep -q 'VideoMotionServiceHooks.install' "$PREMIUM_SERVICES"
grep -q 'COLOROS_VIDEO_PACKAGE = "com.coloros.video"' "$VIDEO_SERVICE"
grep -q 'COLOROS_PLAYBACK_PAUSE_GRACE_MS = 700L' "$VIDEO_SERVICE"
grep -q 'COLOROS_PLAYBACK_RESUME_DELAY_MS = 250L' "$VIDEO_SERVICE"
grep -q 'ColorosVideoPlaybackHooks.install' "$PREMIUM_ENTRY"
test -f "$BILIBILI_STORY"
if grep -R -q 'BilibiliStoryHooks.install' "$HOOK_ROOT/java" \
        "$HOOK_ROOT/java-free" "$HOOK_ROOT/java-premium"; then
    echo 'FAIL: stopped Bilibili Story Hook is installed by a release entry point' >&2
    exit 1
fi
grep -q '"notifyOnIsPlayingChanged"' "$COLOROS_PLAYER"
grep -q '"notifyOnCompletion"' "$COLOROS_PLAYER"
grep -q 'Settings.Global.putString' "$COLOROS_PLAYER"
grep -q 'registerContentObserver' "$VIDEO_SERVICE"
if grep -qE 'MediaSessionRecord|setPlaybackState|COLOROS_SESSION_STATES' "$VIDEO_SERVICE"; then
    echo 'FAIL: ColorOS playback lifecycle still depends on MediaSession state' >&2
    exit 1
fi
grep -q 'NotificationLtpoHooks.install' "$PREMIUM_SERVICES"
grep -q 'NotificationManagerService' "$NOTIFICATION_LTPO"
grep -q 'enqueueNotificationInternal' "$NOTIFICATION_LTPO"
grep -q 'BridgeClient.boostLtpo' "$NOTIFICATION_LTPO"
grep -q 'request("LTPOBOOST", 1000)' "$BRIDGE"
grep -q 'request("VIDEOSTART FOLLOW", RESOLUTION_TIMEOUT_MS)' "$BRIDGE"
grep -q 'request("VIDEOSTART VENDOR", RESOLUTION_TIMEOUT_MS)' "$BRIDGE"
grep -q 'request("VIDEOSTART " + fps, RESOLUTION_TIMEOUT_MS)' "$BRIDGE"
grep -q 'request("VIDEOEND", RESOLUTION_TIMEOUT_MS)' "$BRIDGE"
grep -q 'isShowDialogFhd' "$VIDEO"
grep -q 'mSettingsColorJumpPreference' "$VIDEO"
grep -q 'refreshMotionSummary' "$VIDEO"
grep -q 'R1 扩展实验输出' "$VIDEO"
grep -q 'isNativeMemcRate' "$VIDEO"
grep -q 'onBindViewHolder' "$SETTINGS_UI"
grep -q 'refreshUiData' "$SETTINGS_UI"
grep -q 'RATE_CACHE' "$SETTINGS_UI"
grep -q 'WORKER.execute' "$SETTINGS_UI"
grep -q 'Reflect.setField(preference, "mSupportRefreshRateValue", labels)' \
    "$SETTINGS_UI"
grep -q 'rateFromOverrideValue' "$SETTINGS_UI"
grep -q 'return rates.get(rates.size() - 1) + "Hz"' "$SETTINGS_UI"
PATCHED_OVERRIDE_BODY=$(sed -n '/private static Object getOverrideRate/,/private static Integer rateFromOverrideValue/p' \
    "$SETTINGS_UI")
if printf '%s\n' "$PATCHED_OVERRIDE_BODY" | sed -n '/if (rates == null)/,$p' | \
        tail -n +4 | grep -q 'chain.proceed()'; then
    echo 'FAIL: patched Settings override can reach the stock four-entry array' >&2
    exit 1
fi
grep -q 'if (rateId >= 30 && rateId <= 1000)' "$SERVICES"
grep -q 'DISPLAY_HOOK_PACKAGE="com.murongchaopin.displayhook"' "$ROOT/service.sh"

echo 'PASS: API 102 free base and paid Settings/Game Assistant/Scene scopes are isolated'
