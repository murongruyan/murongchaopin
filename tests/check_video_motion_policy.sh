#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DAEMON="$ROOT/src/rate_daemon.c"
VIDEO="$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/VideoMotionHooks.java"
SERVICE="$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/VideoMotionServiceHooks.java"
COLOROS_PLAYER="$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/ColorosVideoPlaybackHooks.java"
BILIBILI_STORY="$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/BilibiliStoryHooks.java"
OPLUS_SERVICES="$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/PremiumServiceHooks.java"

grep -q '"VIDEOSTART FOLLOW"' "$DAEMON"
grep -q '"VIDEOSTART VENDOR"' "$DAEMON"
grep -q '"VIDEOSTART %d"' "$DAEMON"
grep -q '"VIDEOEND"' "$DAEMON"
grep -q 'resolve_video_override_mode' "$DAEMON"
grep -q 'if (video_override_follow) return default_mode_id;' "$DAEMON"
grep -q 'width = get_mode_width(default_mode_id);' "$DAEMON"
grep -q 'mode_for_width_fps(width, video_override_fps)' "$DAEMON"
grep -q 'load_config(base_path);' "$DAEMON"
grep -q 'video_override_active' "$DAEMON"
grep -q 'Video temporary mode cleared on screen off' "$DAEMON"
grep -q 'mode_txt_unchanged=Y' "$DAEMON"
grep -q 'RMX5200_IRIS_ESD_CTRL_PATH' "$DAEMON"
grep -q 'session_ctrl = current_ctrl & ~0x1U;' "$DAEMON"
grep -q 'chip self-check paused, recovery retained' "$DAEMON"
grep -q 'persist_video_iris_esd_saved' "$DAEMON"
grep -q 'restore_video_iris_esd(base_path);' "$DAEMON"
grep -q 'RMX5200_VIDEO_IRIS_EXIT_STUCK_LOG_MS' "$DAEMON"
grep -q 'RMX5200_VIDEO_IRIS_EXIT_SETTLE_MS 5000' "$DAEMON"
grep -q 'video_iris_memc_active()' "$DAEMON"
grep -q 'queue_video_iris_esd_restore();' "$DAEMON"
grep -q 'maybe_restore_video_iris_esd(base_path);' "$DAEMON"
grep -q 'recover_video_iris_esd_on_startup(base_path);' "$DAEMON"
grep -q 'Recovered active RMX5200 MEMC session after daemon restart' "$DAEMON"
grep -q 'video_exit_pending = video_iris_esd_restore_pending;' "$DAEMON"
grep -q 'ESD restore held to prevent DPMS recovery' "$DAEMON"
grep -q 'reached bypass; keeping display ownership' "$DAEMON"
grep -q 'waiting_for_iris_bypass=Y' "$DAEMON"
grep -q 'Video exit mode drift detected' "$DAEMON"
grep -q 'video_override_active || video_handoff_active ||' "$DAEMON"

SYNC_SETTINGS=$(sed -n '/void sync_android_settings(int id) {/,/^}/p' "$DAEMON")
COLOROS_SETTLE_LINE=$(printf '%s\n' "$SYNC_SETTINGS" | grep -n 'usleep(350000)' |
    head -n 1 | cut -d: -f1)
PEAK_REASSERT_LINE=$(printf '%s\n' "$SYNC_SETTINGS" |
    grep -n 'write_setting_int("system", "peak_refresh_rate", fps);' |
    head -n 1 | cut -d: -f1)
USER_REASSERT_LINE=$(printf '%s\n' "$SYNC_SETTINGS" |
    grep -n 'write_setting_int("system", "user_refresh_rate", fps);' |
    head -n 1 | cut -d: -f1)
DEFAULT_REASSERT_LINE=$(printf '%s\n' "$SYNC_SETTINGS" |
    grep -n 'write_setting_int("system", "default_refresh_rate", fps);' |
    head -n 1 | cut -d: -f1)
[ -n "$COLOROS_SETTLE_LINE" ] && [ -n "$PEAK_REASSERT_LINE" ] &&
    [ "$COLOROS_SETTLE_LINE" -lt "$PEAK_REASSERT_LINE" ] &&
    [ "$PEAK_REASSERT_LINE" -lt "$USER_REASSERT_LINE" ] &&
    [ "$USER_REASSERT_LINE" -lt "$DEFAULT_REASSERT_LINE" ] || {
    echo 'FAIL: ColorOS refresh observer can overwrite the restored user ceiling' >&2
    exit 1
}

START_BODY=$(sed -n '/static int start_video_override(const char \*base_path, int follow, int fps) {/,/^}/p' "$DAEMON")
STOP_BODY=$(sed -n '/static int stop_video_override(const char \*base_path, const char \*reason) {/,/^}/p' "$DAEMON")
for body in "$START_BODY" "$STOP_BODY"; do
    printf '%s\n' "$body" | grep -q 'apply_hook_mode_request'
    if printf '%s\n' "$body" | grep -Eq 'write_(global|resolution|app)_config'; then
        echo 'FAIL: temporary video mode writes durable mode.txt state' >&2
        exit 1
    fi
done

MAIN_POLICY=$(sed -n '/if (video_exit_pending) {/,/smooth_switch(target_id);/p' "$DAEMON" | tail -n 80)
printf '%s\n' "$MAIN_POLICY" | grep -q 'resolve_video_override_mode();'
printf '%s\n' "$MAIN_POLICY" | grep -q 'target_id = -1;'
printf '%s\n' "$MAIN_POLICY" | grep -q 'Deliberately idle during Iris exit'
printf '%s\n' "$START_BODY" | grep -q 'sync_oti_pause_policy(base_path, 1);'
printf '%s\n' "$STOP_BODY" | grep -q 'sync_oti_pause_policy(base_path, 1);'
printf '%s\n' "$STOP_BODY" | grep -q 'update_rmx5200_ltpo_controller(base_path, default_mode_id'
printf '%s\n' "$STOP_BODY" | grep -q 'write_setting_int("system", "min_refresh_rate", 60);'
printf '%s\n' "$START_BODY" | grep -q 'video_handoff_active = 1;'
printf '%s\n' "$START_BODY" | grep -q 'current_mode_id = observed_id;'
printf '%s\n' "$START_BODY" | grep -q 'Video refresh handoff acquired physical source'
if printf '%s\n' "$START_BODY" | grep -q 'apply_refresh_ladder(default_mode_id)'; then
    echo 'FAIL: MEMC entry still climbs to the durable user ceiling first' >&2
    exit 1
fi
printf '%s\n' "$START_BODY" | grep -q 'prepare_video_iris_esd(base_path)'
printf '%s\n' "$START_BODY" | grep -q 'Video temporary mode unchanged'
VENDOR_HOLD_BODY=$(sed -n '/static int start_video_vendor_hold(const char \*base_path) {/,/^}/p' "$DAEMON")
printf '%s\n' "$VENDOR_HOLD_BODY" | grep -q 'video_override_vendor_owned = 1;'
printf '%s\n' "$VENDOR_HOLD_BODY" | grep -q 'physical_mode_unchanged=Y'
if printf '%s\n' "$VENDOR_HOLD_BODY" | grep -q 'apply_hook_mode_request'; then
    echo 'FAIL: vendor-owned MEMC hold submits a physical mode' >&2
    exit 1
fi
grep -q 'video_exit_pending ||' "$DAEMON"
grep -q '(video_override_active && video_override_vendor_owned)' "$DAEMON"
PREPARE_ESD_LINE=$(printf '%s\n' "$START_BODY" | grep -n 'prepare_video_iris_esd(base_path)' | head -n 1 | cut -d: -f1)
grep -q 'Claim the display before submitting the target' "$DAEMON"
grep -q 'pause = video_override_active || video_handoff_active ||' "$DAEMON"
OTI_POLICY=$(sed -n '/static void sync_oti_pause_policy/,/^}/p' "$DAEMON")
if printf '%s\n' "$OTI_POLICY" | grep -q 'video_exit_pending'; then
    echo 'FAIL: MEMC exit still owns OTI pause' >&2
    exit 1
fi
FRAMEWORK_FLOOR=$(sed -n '/static int framework_min_refresh_floor(int fps)/,/^}/p' "$DAEMON")
if printf '%s\n' "$FRAMEWORK_FLOOR" | grep -q 'video_exit_pending'; then
    echo 'FAIL: MEMC exit still owns the fixed framework floor' >&2
    exit 1
fi
VIDEO_CLAIM_LINE=$(printf '%s\n' "$START_BODY" | grep -n 'video_override_active = 1;' | head -n 1 | cut -d: -f1)
VIDEO_APPLY_LINE=$(printf '%s\n' "$START_BODY" | grep -n 'apply_hook_mode_request' | head -n 1 | cut -d: -f1)
VIDEO_HANDOFF_LINE=$(printf '%s\n' "$START_BODY" | grep -n 'video_handoff_active = 1;' | head -n 1 | cut -d: -f1)
[ -n "$PREPARE_ESD_LINE" ] && [ "$PREPARE_ESD_LINE" -lt "$VIDEO_HANDOFF_LINE" ] && \
    [ "$PREPARE_ESD_LINE" -lt "$VIDEO_APPLY_LINE" ] || {
    echo 'FAIL: Iris ESD session policy is applied after the MEMC mode transaction' >&2
    exit 1
}
[ -n "$VIDEO_CLAIM_LINE" ] && [ -n "$VIDEO_APPLY_LINE" ] && \
    [ "$VIDEO_CLAIM_LINE" -lt "$VIDEO_APPLY_LINE" ] || {
    echo 'FAIL: MEMC display ownership is claimed after its mode transaction' >&2
    exit 1
}
[ -n "$VIDEO_HANDOFF_LINE" ] && [ "$VIDEO_HANDOFF_LINE" -lt "$VIDEO_CLAIM_LINE" ] && \
    [ "$VIDEO_HANDOFF_LINE" -lt "$VIDEO_APPLY_LINE" ] || {
    echo 'FAIL: video owns/submits its target before acquiring the physical source' >&2
    exit 1
}
printf '%s\n' "$START_BODY" | grep -q 'update_rmx5200_ltpo_controller(base_path, target_id'
printf '%s\n' "$STOP_BODY" | grep -q 'clear_video_override(base_path)'
printf '%s\n' "$STOP_BODY" | grep -q 'maybe_restore_video_iris_esd(base_path)'
grep -q 'Video temporary mode drift detected' "$DAEMON"
grep -q 'applied_id = get_current_applied_mode();' "$DAEMON"
grep -q 'force_reapply = 1;' "$DAEMON"

grep -q 'VideoMotionPolicy.write' "$VIDEO"
grep -q 'isNativeMemcRate' "$VIDEO"
grep -q 'rate == 60 || rate == 90 || rate == 120 || rate == 144' \
    "$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/VideoMotionPolicy.java"
grep -q 'static boolean usesVendorScreenRate(int rate)' \
    "$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/VideoMotionPolicy.java"
grep -q 'return rate == 60 || rate == 90 || rate == 120;' \
    "$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/VideoMotionPolicy.java"
grep -q 'return outputRate > 0 && outputRate <= 60 ? 60 : 120;' \
    "$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/VideoMotionPolicy.java"
grep -q 'static boolean isDirectR1Rate(int rate)' \
    "$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/VideoMotionPolicy.java"
grep -q 'return rate > 120;' \
    "$ROOT/src/settings_hook/java-premium/com/murongchaopin/displayhook/VideoMotionPolicy.java"
if grep -q 'BridgeClient.setGlobalMode' "$VIDEO"; then
    echo 'FAIL: Settings selection performs an immediate display transaction' >&2
    exit 1
fi
grep -q 'chain.proceed()' "$SERVICE"
grep -q 'Allowed vendor MEMC screen-rate handshake' "$SERVICE"
SCREEN_RATE_BODY=$(sed -n '/if ("requestScreenRate"\.equals(method\.getName())/,/} else if ("updateStateMachine"/p' "$SERVICE")
printf '%s\n' "$SCREEN_RATE_BODY" | grep -q 'Object result = chain.proceed();'
printf '%s\n' "$SCREEN_RATE_BODY" | grep -q 'return result;'
printf '%s\n' "$SCREEN_RATE_BODY" | grep -q 'startSession(module, target)'
printf '%s\n' "$SCREEN_RATE_BODY" | grep -q 'Blocked vendor MEMC screen-rate handshake'
printf '%s\n' "$SCREEN_RATE_BODY" | grep -q 'CUSTOM_RATE_VOTES.put(ownerInstance, target)'
printf '%s\n' "$SCREEN_RATE_BODY" | grep -q 'Replaced vendor MEMC screen-rate vote'
grep -q 'mIrisMemc' "$SERVICE"
grep -q 'onActivityEnter' "$SERVICE"
grep -q 'onAppEnter' "$SERVICE"
grep -q 'mActivityEnter' "$SERVICE"
grep -q 'mMEMCCmd' "$SERVICE"
grep -q 'checkTopActivity' "$SERVICE"
grep -q 'mNeedClosePWFunctions' "$SERVICE"
grep -q 'mLowPowerMode' "$SERVICE"
grep -q 'mHighTemperatureEnable' "$SERVICE"
grep -q 'mPIPMode' "$SERVICE"
grep -q 'mSplitMode' "$SERVICE"
grep -q 'isPortraitMemcEligible' "$SERVICE"
grep -q 'PORTRAIT_ROTATION_OVERRIDE' "$SERVICE"
grep -q 'scheduleInputTimingPrime' "$SERVICE"
grep -q 'INPUT_TIMING_POLL_DELAY_MS = 200L' "$SERVICE"
grep -q 'INPUT_TIMING_MIN_SETTLE_MS = 900L' "$SERVICE"
grep -q 'INPUT_TIMING_NATIVE_GRACE_MS = 2200L' "$SERVICE"
grep -q 'INPUT_TIMING_READY_TIMEOUT_MS = 7000L' "$SERVICE"
grep -q 'INPUT_TIMING_STABLE_SAMPLES = 3' "$SERVICE"
grep -q 'MEMC_INPUT_MAX_REFRESH_RATE = 60.5f' "$SERVICE"
grep -q 'MEMC_VENDOR_INPUT_RATE_HZ = 60' "$SERVICE"
grep -q 'timing stabilized' "$SERVICE"
grep -q 'pending.stableLowSamples' "$SERVICE"
grep -q 'pending.vendorInputFallbackAllowed' "$SERVICE"
grep -q 'applyVendorInputTimingFallback' "$SERVICE"
grep -q 'Pixelworks vendor input-timing hold replay' "$SERVICE"
grep -q 'beginBilibiliTransientRateHold(module, ownerInstance)' "$SERVICE"
grep -q 'PENDING_BILIBILI_TRANSIENT_RATE_HOLDS' "$SERVICE"
grep -q 'BILIBILI_TRANSIENT_RATE_HOLD_MS = 3500L' "$SERVICE"
grep -q 'expireBilibiliTransientRateHold' "$SERVICE"
grep -q 'BILIBILI_STORY_INPUT_RECOVERIES' "$SERVICE"
grep -q 'claimBilibiliStoryInputRecovery(owner)' "$SERVICE"
grep -q 'recycling vendor MEMC session once' "$SERVICE"
grep -q 'Reflect.call(owner, "updateStateMachine", Boolean.FALSE)' "$SERVICE"
if grep -q 'INPUT_TIMING_HANDSHAKE_REPLAY' "$SERVICE"; then
    echo 'FAIL: ineffective Story screen-rate vote replay loop remains' >&2
    exit 1
fi
grep -q 'Held vendor MEMC screen-rate release during' "$SERVICE"
grep -q 'transientBilibiliClose || storyPageRateHold(owner) != null' "$SERVICE"
grep -q 'pending.handler.sendEmptyMessage(MSG_SET_MEMC_PARAMETERS)' "$SERVICE"
grep -q 'Bilibili Story MEMC parameters held until 60Hz input is stable' "$SERVICE"
grep -q 'isBilibiliStoryActivity(owner)' "$SERVICE"
grep -q 'MEMC parameters remain input-gated' "$SERVICE"
grep -q 'scheduleVideoLayerReplay' "$SERVICE"
grep -q 'VIDEO_LAYER_REPLAY_DELAY_MS' "$SERVICE"
grep -q 'scheduleBilibiliRotationRecovery' "$SERVICE"
grep -q 'BILIBILI_ROTATION_RECOVERY_DELAY_MS = 1200L' "$SERVICE"
grep -q 'PENDING_BILIBILI_ROTATION_RECOVERIES' "$SERVICE"
grep -q 'Reflect.call(owner, "updateStateMachine", Boolean.TRUE)' "$SERVICE"
grep -q 'scheduleBilibiliActivityReentry' "$SERVICE"
grep -q 'BILIBILI_ACTIVITY_REENTRY_WINDOW_MS = 1000L' "$SERVICE"
grep -q 'BILIBILI_ACTIVITY_REENTRY_DELAY_MS = 2200L' "$SERVICE"
grep -q 'PENDING_BILIBILI_REENTRIES' "$SERVICE"
grep -q 'BILIBILI_DEFERRED_OPEN' "$SERVICE"
grep -q 'BILIBILI_ACTIVITY_EXITING' "$SERVICE"
grep -q 'markBilibiliActivityExit' "$SERVICE"
grep -q 'BILIBILI_RATE_RELEASE_DELAY_MS = 3500L' "$SERVICE"
grep -q 'PENDING_BILIBILI_RATE_RELEASES' "$SERVICE"
grep -q 'BILIBILI_DEFERRED_RATE_RELEASE' "$SERVICE"
grep -q 'Held vendor MEMC screen-rate release' "$SERVICE"
grep -q 'cancelPendingBilibiliRateRelease' "$SERVICE"
grep -q 'static boolean isBilibiliPlayerComponent' "$SERVICE"
grep -q 'COLOROS_VIDEO_PACKAGE = "com.coloros.video"' "$SERVICE"
grep -q 'COLOROS_PLAYBACK_PAUSE_GRACE_MS = 700L' "$SERVICE"
grep -q 'COLOROS_PLAYBACK_RESUME_DELAY_MS = 250L' "$SERVICE"
grep -q 'Settings.Global.getUriFor(ColorosVideoPlaybackHooks.PLAYBACK_SETTING)' "$SERVICE"
grep -q 'BILIBILI_STORY_PAGE_CLOSE' "$SERVICE"
grep -q 'BILIBILI_STORY_PAGE_RATE_HOLDS' "$SERVICE"
grep -q 'Held vendor MEMC screen-rate release during' "$SERVICE"
grep -q 'Retained MEMC temporary mode during Bilibili Story' "$SERVICE"
grep -q 'transientBilibiliClose || storyPageRateHold(owner) != null' "$SERVICE"
grep -q 'storyPageRateHold(ownerInstance)' "$SERVICE"
grep -q 'new StoryPageRateHold(eventUptimeMillis)' "$SERVICE"
grep -q 'BILIBILI_STORY_PAGE_RATE_HOLDS.remove(owner)' "$SERVICE"
grep -q 'prepareBilibiliStoryPage' "$SERVICE"
grep -q 'queueBilibiliStoryFirstFrame' "$SERVICE"
grep -q 'openBilibiliStoryAfterFirstFrame' "$SERVICE"
test -f "$BILIBILI_STORY"
grep -q 'StoryPagerPlayer\$f' "$BILIBILI_STORY"
grep -q 'StoryPlayer\$v' "$BILIBILI_STORY"
grep -q 'signalStoryPageEvent(EVENT_PREPARE)' "$BILIBILI_STORY"
grep -q 'signalStoryPageEvent(EVENT_FIRST_FRAME)' "$BILIBILI_STORY"
grep -q 'bilibili_uid = package_uid("tv.danmaku.bili")' "$DAEMON"
grep -q 'STORYPAGE %15s %lld' "$DAEMON"
grep -q 'murong_bilibili_story_memc_event' "$DAEMON"
grep -q 'registerContentObserver' "$SERVICE"
grep -q 'isColorosPlaybackKnownStopped' "$SERVICE"
grep -q 'PENDING_COLOROS_TRANSITIONS' "$SERVICE"
grep -q 'Reflect.call(owner, "updateStateMachine", Boolean.FALSE)' "$SERVICE"
test -f "$COLOROS_PLAYER"
grep -q 'ABSTRACT_MEDIA_PLAYER =' "$COLOROS_PLAYER"
grep -q '"com.oplus.tblplayer.AbstractMediaPlayer"' "$COLOROS_PLAYER"
grep -q '"notifyOnIsPlayingChanged"' "$COLOROS_PLAYER"
grep -q '"notifyOnCompletion"' "$COLOROS_PLAYER"
grep -q 'Settings.Global.putString' "$COLOROS_PLAYER"
grep -q 'PLAYBACK_SETTING = "murong_coloros_video_playback"' "$COLOROS_PLAYER"
if grep -qE 'MediaSessionRecord|setPlaybackState|COLOROS_SESSION_STATES' "$SERVICE"; then
    echo 'FAIL: ColorOS playback lifecycle still depends on MediaSession state' >&2
    exit 1
fi
grep -q 'hookMemcAppSwitchBoost' "$OPLUS_SERVICES"
grep -q '"startAppSwitchBoost"' "$OPLUS_SERVICES"
grep -q '"stopAppSwitchBoostIfNeeded"' "$OPLUS_SERVICES"
grep -q 'MEMC_SWITCH = "osie_motion_fluency_switch"' "$OPLUS_SERVICES"
grep -q 'MEMC_CONFIG =' "$OPLUS_SERVICES"
grep -q 'Xml.newPullParser()' "$OPLUS_SERVICES"
grep -q '"mConfigActivity".equals(parser.getName())' "$OPLUS_SERVICES"
grep -q 'loadMemcPlayerComponents' "$OPLUS_SERVICES"
grep -q 'normalizeComponent' "$OPLUS_SERVICES"
grep -q 'playerComponents.contains(packageName + "/" + activity)' "$OPLUS_SERVICES"
grep -q 'VideoMotionServiceHooks.isBilibiliPlayerComponent' "$OPLUS_SERVICES"
grep -q 'static boolean isVendorMemcActive()' "$SERVICE"
grep -q 'ACTIVE_STATES.containsValue(Boolean.TRUE)' "$SERVICE"
grep -q 'PremiumGateBridge.isVendorMemcActive()' \
    "$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/FrameworkPhysicalEnvelopeHooks.java"
grep -q 'setPhysicalRange(specs, "primary", memcInputRate)' \
    "$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/FrameworkPhysicalEnvelopeHooks.java"
grep -q 'MSG_SET_ENTER_SCREEN_RATE = 1001' "$SERVICE"
grep -q 'handler.sendEmptyMessage(MSG_SET_ENTER_SCREEN_RATE)' "$SERVICE"
grep -q 'MEMC_PARAMETERS_DELAY_MS = 600L' "$SERVICE"
if grep -qE 'Reflect\.setField\(owner, "m(IrisMemc|LastIrisMemc)", true\)' "$SERVICE"; then
    echo 'FAIL: MEMC hook still forges vendor state-machine fields' >&2
    exit 1
fi
grep -q 'MSG_SET_MEMC_PARAMETERS = 1003' "$SERVICE"
grep -q 'handler.sendEmptyMessageDelayed(MSG_SET_MEMC_PARAMETERS' "$SERVICE"
grep -q 'Reflect.staticFieldAssignableTo(owner.getClass(), Context.class)' "$SERVICE"
grep -q 'VideoMotionPolicy.memcTarget(target)' "$SERVICE"
grep -q 'VideoMotionPolicy.isDirectR1Rate(selectedTarget)' "$SERVICE"
grep -q 'boolean vendorScreenRate = VideoMotionPolicy.usesVendorScreenRate(selectedTarget);' "$SERVICE"
grep -q 'int outputTarget = directR1' "$SERVICE"
grep -q 'int appliedTarget = vendorScreenRate ? -1 : outputTarget;' "$SERVICE"
grep -q 'BridgeClient.startVideoModeVendorOwned()' "$SERVICE"
grep -q 'request("VIDEOSTART VENDOR", RESOLUTION_TIMEOUT_MS)' \
    "$ROOT/src/settings_hook/java/com/murongchaopin/displayhook/BridgeClient.java"
grep -q 'VideoMotionPolicy.usesVendorScreenRate(selectedTarget)' "$SERVICE"
grep -q 'vendor-owned' "$SERVICE"
grep -q 'screenTiming=' "$SERVICE"
grep -q 'vendorScreenRate=' "$SERVICE"
grep -q 'endVideoMode' "$SERVICE"

echo 'PASS: video policy follows mode.txt only during a real MEMC session'
