package com.murongchaopin.displayhook;

import android.util.SparseArray;

import java.lang.reflect.Method;

/**
 * ColorOS resolves a refresh-rate tier through
 * {@code com.oplus.vrr.OPlusRefreshRateConfigs.getModeId(modeType, rate, w, h)}.
 *
 * That lookup is keyed by the SurfaceFlinger "mode type" (SA/SM/OA/OM) which the
 * platform reads with SurfaceFlinger transaction 23005.  A module that injects
 * extra timings makes SurfaceFlinger report type 0 for every mode, so the type
 * map holds no entry for the requested tier and the call returns -1.  Display
 * Manager then logs "Can't find display mode with id -1", keeps re-applying a
 * fallback mode and the panel flips between groups on every refresh-rate switch:
 * that flapping is the visible flash.
 *
 * This hook keeps the vendor answer whenever it is valid and otherwise resolves
 * the request against the real mode list by refresh rate and geometry, falling
 * back to the tier the daemon selected (config/mode.txt).
 */
final class OplusVrrTierHooks {
    private static final String CONFIGS = "com.oplus.vrr.OPlusRefreshRateConfigs";
    private static final String TARGET_FILE =
            "/data/adb/modules/murongchaopin/config/mode.txt";
    private static final float RATE_EPSILON_HZ = 0.01f;
    /** The rate the vendor LTPS algorithm asks for when the screen is idle. */
    private static final float LTPS_IDLE_RATE_HZ = 60.0f;
    private static volatile String lastRouteDecision = "";

    private OplusVrrTierHooks() {
    }

    /** Policy classes that turn a ColorOS tier into a concrete mode id. */
    private static final String[] POLICY_CLASSES = {
            "com.oplus.vrr.OPlusRefreshRatePolicy",
            "com.oplus.vrr.OPlusRefreshRateService",
    };

    private static final String LOCAL_DISPLAY_DEVICE =
            "com.android.server.display.LocalDisplayAdapter$LocalDisplayDevice";
    private static final java.util.concurrent.atomic.AtomicInteger EVENT_LOGS =
            new java.util.concurrent.atomic.AtomicInteger();

    /**
     * SurfaceFlinger reports the active mode of an injected config with id -1.
     * DisplayManagerService then fails the lookup, falls back to another mode and
     * publishes it again, which walks the panel through the other resolution
     * group until the ids line up: that walk is the visible flash.  The current
     * mode is also refreshed through the ordinary device-info path, so an event
     * without a usable mode id carries nothing we need.
     */
    /**
     * SurfaceFlinger reports {@code DynamicDisplayInfo.activeDisplayModeId = -1}
     * while an injected timing is the active config.  DisplayManagerService then
     * cannot resolve the current mode, re-publishes a fallback mode and walks the
     * panel across resolution groups until the ids line up again - the visible
     * flash.  Resolve those requests with the mode the device already knows.
     */
    static int installActiveModeHooks(DisplaySettingsHook module, ClassLoader loader) {
        int installed = 0;
        try {
            Class<?> owner = Class.forName(LOCAL_DISPLAY_DEVICE, false, loader);
            for (Method method : owner.getDeclaredMethods()) {
                Class<?>[] parameters = method.getParameterTypes();
                if ("findMatchingModeIdLocked".equals(method.getName())
                        && method.getReturnType() == int.class
                        && parameters.length == 1
                        && parameters[0] == int.class) {
                    method.setAccessible(true);
                    module.intercept(method, "framework.mode.match", chain -> {
                        int sfModeId = ((Number) chain.getArg(0)).intValue();
                        Object result = chain.proceed();
                        if (sfModeId >= 0 || !(result instanceof Number)
                                || ((Number) result).intValue() >= 0) {
                            return result;
                        }
                        Integer known = currentModeId(chain.getThisObject());
                        if (known != null && EVENT_LOGS.incrementAndGet() <= 8) {
                            module.info("Resolved SurfaceFlinger mode id -1 with active"
                                    + " framework mode " + known);
                        }
                        return known == null ? result : known;
                    });
                    installed++;
                } else if ("getActiveDisplayModeAtStartLocked".equals(method.getName())
                        && method.getReturnType() == android.view.Display.Mode.class
                        && parameters.length == 0) {
                    method.setAccessible(true);
                    module.intercept(method, "framework.mode.start", chain -> {
                        Object result = chain.proceed();
                        if (result != null) {
                            return result;
                        }
                        Integer known = currentModeId(chain.getThisObject());
                        if (known == null) {
                            return null;
                        }
                        if (EVENT_LOGS.incrementAndGet() <= 8) {
                            module.info("Active display mode at start resolved from"
                                    + " framework mode " + known);
                        }
                        Object mode = modeForId(chain.getThisObject(), known);
                        return mode;
                    });
                    installed++;
                }
            }
        } catch (Throwable error) {
            module.error("Framework active mode hook unavailable", error);
        }
        return installed;
    }

    private static Object modeForId(Object device, int modeId) {
        try {
            Object value = Reflect.getField(device, "mSupportedModes");
            if (!(value instanceof SparseArray<?>)) {
                return null;
            }
            Object record = ((SparseArray<?>) value).get(modeId);
            return record == null ? null : Reflect.getField(record, "mMode");
        } catch (Throwable ignored) {
            return null;
        }
    }
    private static Integer currentModeId(Object device) {
        Object value = field(device, "mActiveModeId");
        if (value instanceof Number) {
            int modeId = ((Number) value).intValue();
            if (modeId >= 0) {
                return modeId;
            }
        }
        return null;
    }
    private static final String DISPLAY_MODE_DIRECTOR_OBSERVER =
            "com.android.server.display.mode.DisplayModeDirector$AppRequestObserver";
    private static final ThreadLocal<Boolean> APP_REQUEST_REENTRY =
            ThreadLocal.withInitial(() -> Boolean.FALSE);
    private static final java.util.concurrent.atomic.AtomicInteger APP_REQUEST_LOGS =
            new java.util.concurrent.atomic.AtomicInteger();

    /**
     * DisplayModeDirector keeps two ceilings for the app: the render vote built
     * from peak_refresh_rate and the app-request range aimed at the top window.
     * ColourOS derives that second range from its refresh tier (144 on this
     * build, 120 in the default mode), so the effective app rate is the tier and
     * never the overclock rate the panel is running at.  Raise the app range to
     * the module selection when it asks for a lower high-rate ceiling.
     */
    private static final java.util.concurrent.atomic.AtomicBoolean MODULE_RATE_PRIMED =
            new java.util.concurrent.atomic.AtomicBoolean();

    static int installAppRequestHooks(DisplaySettingsHook module, ClassLoader loader) {
        // Install runs on an LSPosed worker before the first framework
        // callback: one blocking GETGLOBAL here is what lets the FIRST
        // setAppRequest of this process raise the ceiling. The async refresh
        // cannot, because it returns before the worker's answer lands.
        if (MODULE_RATE_PRIMED.compareAndSet(false, true)) {
            int primed = BridgeClient.primeGlobalRate();
            if (primed >= 30) {
                moduleRateCache = primed;
                moduleRateCachedAt = android.os.SystemClock.elapsedRealtime();
            }
        }
        int installed = 0;
        try {
            Class<?> owner = Class.forName(DISPLAY_MODE_DIRECTOR_OBSERVER, false, loader);
            for (Method method : owner.getDeclaredMethods()) {
                Class<?>[] parameters = method.getParameterTypes();
                if (!"setAppRequest".equals(method.getName())
                        || method.getReturnType() != void.class
                        || parameters.length != 5
                        || parameters[0] != int.class
                        || parameters[1] != int.class
                        || parameters[2] != float.class
                        || parameters[3] != float.class
                        || parameters[4] != float.class) {
                    continue;
                }
                method.setAccessible(true);
                module.intercept(method, "framework.app-request", chain -> {
                    if (Boolean.TRUE.equals(APP_REQUEST_REENTRY.get())) {
                        return chain.proceed();
                    }
                    float maximum = ((Number) chain.getArg(4)).floatValue();
                    int target = moduleTargetRate();
                    if (target < 30 || maximum <= 0.0f || maximum >= (float) target) {
                        return chain.proceed();
                    }
                    if (APP_REQUEST_LOGS.incrementAndGet() <= 10) {
                        module.info("App frame-rate ceiling raised from " + maximum
                                + " to the module selection " + target);
                    }
                    APP_REQUEST_REENTRY.set(Boolean.TRUE);
                    try {
                        Reflect.call(chain.getThisObject(), "setAppRequest",
                                chain.getArg(0), chain.getArg(1), chain.getArg(2),
                                chain.getArg(3), (float) target);
                    } catch (Throwable error) {
                        module.error("App request raise failed", error);
                    } finally {
                        APP_REQUEST_REENTRY.remove();
                    }
                    return null;
                });
                installed++;
            }
        } catch (Throwable error) {
            module.error("DisplayModeDirector app-request hook unavailable", error);
        }
        return installed;
    }

    private static final long MODULE_RATE_TTL_MS = 5000L;
    private static volatile int moduleRateCache;
    private static volatile long moduleRateCachedAt;

    /**
     * Rate the daemon currently runs. DisplayModeDirector calls this from
     * setAppRequest while it holds WindowManagerGlobalLock, so it only reads
     * the volatile snapshot and lets the bridge refresh worker do the I/O.
     */
    private static int moduleTargetRate() {
        long now = android.os.SystemClock.elapsedRealtime();
        int cached = moduleRateCache;
        if (cached >= 30 && now - moduleRateCachedAt < MODULE_RATE_TTL_MS) {
            return cached;
        }
        int value = bridgeModuleRateSnapshot();
        if (value >= 30) {
            moduleRateCache = value;
            moduleRateCachedAt = now;
            return value;
        }
        // Daemon unavailable or backing off: keep the last known rate, and -1
        // when there never was one so the caller keeps its stock behaviour.
        return cached >= 30 ? cached : -1;
    }

    /** Non-blocking bridge read; the refresh itself runs on the bridge worker. */
    private static int bridgeModuleRateSnapshot() {
        BridgeClient.refreshGlobalRateAsync();
        return BridgeClient.globalRateSnapshot();
    }
    static int installEventHooks(DisplaySettingsHook module, ClassLoader loader) {
        int installed = 0;
        try {
            Class<?> owner = Class.forName(LOCAL_DISPLAY_DEVICE, false, loader);
            for (Method method : owner.getDeclaredMethods()) {
                Class<?>[] parameters = method.getParameterTypes();
                if (!"onModeAndFrameRateOverridesChangedLocked".equals(method.getName())
                        || method.getReturnType() != void.class
                        || parameters.length != 6
                        || parameters[0] != int.class) {
                    continue;
                }
                method.setAccessible(true);
                module.intercept(method, "framework.mode.event", chain -> {
                    int sfModeId = ((Number) chain.getArg(0)).intValue();
                    if (sfModeId >= 0) {
                        return chain.proceed();
                    }
                    if (EVENT_LOGS.incrementAndGet() <= 5) {
                        module.info("Ignored SurfaceFlinger mode event without a mode id:"
                                + " render=" + chain.getArg(1));
                    }
                    return null;
                });
                installed++;
            }
        } catch (Throwable error) {
            module.error("Framework mode event hook unavailable", error);
        }
        return installed;
    }
    static int installPolicyHooks(DisplaySettingsHook module, ClassLoader loader) {
        int installed = 0;
        for (String className : POLICY_CLASSES) {
            try {
                Class<?> owner = Class.forName(className, false, loader);
                for (Method method : owner.getDeclaredMethods()) {
                    Class<?>[] parameters = method.getParameterTypes();
                    if (!"findDisplayModeIdByPolicy".equals(method.getName())
                            || method.getReturnType() != int.class
                            || parameters.length != 3
                            || parameters[0] != int.class
                            || parameters[1] != int.class
                            || parameters[2] != int.class) {
                        continue;
                    }
                    method.setAccessible(true);
                    final String tag = className.substring(className.lastIndexOf('.') + 1);
                    module.intercept(method, "oplus.vrr.policy." + tag, chain -> {
                        Object result = chain.proceed();
                        if (result instanceof Number
                                && ((Number) result).intValue() >= 0) {
                            return result;
                        }
                        int policy = ((Number) chain.getArg(0)).intValue();
                        int displayId = ((Number) chain.getArg(1)).intValue();
                        int baseModeId = ((Number) chain.getArg(2)).intValue();
                        Object configs = configsOf(chain.getThisObject(), loader);
                        if (configs == null) {
                            module.info("OPlus VRR policy " + tag
                                    + " unresolved policy=" + policy
                                    + " display=" + displayId
                                    + " base=" + baseModeId + " reason=no-configs");
                            return result;
                        }
                        Integer resolved = resolveForPolicy(module, configs,
                                policy, baseModeId);
                        if (resolved != null) {
                            module.info("OPlus VRR policy " + tag + " mapped policy="
                                    + policy + " display=" + displayId + " base="
                                    + baseModeId + " original=" + result + " mode="
                                    + resolved);
                            return resolved;
                        }
                        module.info("OPlus VRR policy " + tag + " unresolved policy="
                                + policy + " display=" + displayId + " base="
                                + baseModeId + " original=" + result);
                        return result;
                    });
                    installed++;
                }
            } catch (Throwable error) {
                module.error("OPlus VRR policy hook unavailable: " + className, error);
            }
        }
        return installed;
    }

    private static Object configsOf(Object policy, ClassLoader loader) {
        Object configs = field(policy, "mRefreshRateConfigs");
        if (configs != null) {
            return configs;
        }
        try {
            Class<?> type = Class.forName(CONFIGS, false, loader);
            configs = Reflect.fieldAssignableTo(policy, type);
        } catch (Throwable ignored) {
            // Fall through to the singleton lookup below.
        }
        if (configs == null) {
            try {
                Class<?> type = Class.forName(CONFIGS, false, loader);
                configs = Reflect.staticFieldAssignableTo(type, type);
            } catch (Throwable ignored) {
                return null;
            }
        }
        return configs;
    }

    /**
     * ColourOS asks for a tier and hands us the base mode it started from.  When
     * that base is missing or its tier lookup fails we resolve against the module
     * selection first and the base geometry second.
     */
    private static Integer resolveForPolicy(DisplaySettingsHook module, Object configs,
                                            int policy, int baseModeId) {
        int width = -1;
        int height = -1;
        float rate = -1.0f;
        if (baseModeId >= 0) {
            int[] base = modeInfo(configs, baseModeId);
            if (base != null) {
                width = base[0];
                height = base[1];
                rate = modeRate(configs, baseModeId);
            }
        }
        if (width <= 0 || height <= 0) {
            int[] target = readTarget();
            if (target == null) {
                return null;
            }
            width = target[0];
            height = target[1];
        }
        int[] target = readTarget();
        if (target != null && target[0] == width && target[1] == height) {
            Integer selected = modeIdFor(configs, width, height, target[2]);
            if (selected != null) {
                return selected;
            }
        }
        if (rate > 0.0f) {
            Integer exact = modeIdFor(configs, width, height, (int) Math.round(rate));
            if (exact != null) {
                return exact;
            }
        }
        return null;
    }

    private static int[] modeInfo(Object configs, int modeId) {
        try {
            Object modesValue = Reflect.getField(configs, "mSupportedModes");
            if (!(modesValue instanceof SparseArray<?>)) {
                return null;
            }
            Object record = ((SparseArray<?>) modesValue).get(modeId);
            Object displayMode = displayMode(record);
            if (displayMode == null) {
                return null;
            }
            int width = intField(displayMode, "width");
            int height = intField(displayMode, "height");
            return width > 0 && height > 0 ? new int[]{width, height} : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static float modeRate(Object configs, int modeId) {
        try {
            Object modesValue = Reflect.getField(configs, "mSupportedModes");
            if (!(modesValue instanceof SparseArray<?>)) {
                return -1.0f;
            }
            Object displayMode = displayMode(((SparseArray<?>) modesValue).get(modeId));
            return displayMode == null ? -1.0f : refreshRate(displayMode);
        } catch (Throwable ignored) {
            return -1.0f;
        }
    }

    private static Integer modeIdFor(Object configs, int width, int height, int fps) {
        try {
            Object modesValue = Reflect.getField(configs, "mSupportedModes");
            if (!(modesValue instanceof SparseArray<?>)) {
                return null;
            }
            SparseArray<?> modes = (SparseArray<?>) modesValue;
            Integer best = null;
            for (int index = 0; index < modes.size(); index++) {
                int modeId = modes.keyAt(index);
                Object displayMode = displayMode(modes.valueAt(index));
                if (displayMode == null
                        || intField(displayMode, "width") != width
                        || intField(displayMode, "height") != height) {
                    continue;
                }
                if (Math.abs(refreshRate(displayMode) - fps) <= RATE_EPSILON_HZ
                        && (best == null || modeId < best)) {
                    best = modeId;
                }
            }
            return best;
        } catch (Throwable ignored) {
            return null;
        }
    }
    static int install(DisplaySettingsHook module, ClassLoader loader) {
        int installed = 0;
        try {
            Class<?> owner = Class.forName(CONFIGS, false, loader);
            for (Method method : owner.getDeclaredMethods()) {
                Class<?>[] parameters = method.getParameterTypes();
                if (!"getModeId".equals(method.getName())
                        || method.getReturnType() != int.class
                        || parameters.length != 4
                        || parameters[0] != int.class
                        || parameters[1] != float.class
                        || parameters[2] != int.class
                        || parameters[3] != int.class) {
                    continue;
                }
                method.setAccessible(true);
                module.intercept(method, "oplus.vrr.mode-id", chain -> {
                    int modeType = ((Number) chain.getArg(0)).intValue();
                    float rate = ((Number) chain.getArg(1)).floatValue();
                    int width = ((Number) chain.getArg(2)).intValue();
                    int height = ((Number) chain.getArg(3)).intValue();
                    // Pure custom LTPO: the vendor LTPS algorithm decides 60Hz
                    // when the screen is idle. That decision is the route hook --
                    // resolve the *same* request against the injected low tier so
                    // the system itself selects 1Hz, instead of a manual mode set.
                    // Non-blocking: refreshed on the bridge worker, never here.
                    BridgeClient.LtpoRoute route = BridgeClient.ltpoRoute();
                    if (route != null
                            && Math.abs(rate - LTPS_IDLE_RATE_HZ) <= RATE_EPSILON_HZ) {
                        Integer routed = exactModeId(chain.getThisObject(),
                                route.targetFps, width, height);
                        if (routed != null) {
                            String decision = "route request=" + rate
                                    + " target=" + route.targetFps
                                    + " mode=" + routed;
                            synchronized (OplusVrrTierHooks.class) {
                                if (!decision.equals(lastRouteDecision)) {
                                    lastRouteDecision = decision;
                                    module.info("OPlus VRR tier routed " + decision);
                                }
                            }
                            return routed;
                        }
                    }
                    Object result = chain.proceed();
                    if (result instanceof Number
                            && ((Number) result).intValue() >= 0) {
                        return result;
                    }
                    Integer resolved = resolveModeId(chain.getThisObject(),
                            rate, width, height);
                    if (resolved != null) {
                        module.info("OPlus VRR tier resolved type=" + modeType
                                + " request=" + width + "x" + height + "@" + rate
                                + " original=" + result + " mode=" + resolved);
                        return resolved;
                    }
                    module.info("OPlus VRR tier unresolved type=" + modeType
                            + " request=" + width + "x" + height + "@" + rate
                            + " original=" + result);
                    return result;
                });
                installed++;
            }
        } catch (Throwable error) {
            module.error("OPlus VRR tier hook unavailable", error);
        }
        return installed;
    }

/** Exact geometry + rate match; used by the LTPO route so a miss cannot
     * silently fall back to the user's ceiling tier. */
    private static Integer exactModeId(Object configs, float rate, int width,
                                       int height) {
        try {
            Object value = Reflect.getField(configs, "mSupportedModes");
            if (!(value instanceof SparseArray<?>)) {
                return null;
            }
            SparseArray<?> modes = (SparseArray<?>) value;
            Integer selected = null;
            for (int index = 0; index < modes.size(); index++) {
                int modeId = modes.keyAt(index);
                Object displayMode = displayMode(modes.valueAt(index));
                if (displayMode == null) {
                    continue;
                }
                if (intField(displayMode, "width") != width
                        || intField(displayMode, "height") != height
                        || Math.abs(refreshRate(displayMode) - rate)
                            > RATE_EPSILON_HZ) {
                    continue;
                }
                if (selected == null || modeId < selected) {
                    selected = modeId;
                }
            }
            return selected;
        } catch (Throwable ignored) {
            return null;
        }
    }

    /** Returns a mode id for the request, or null when nothing matches. */
    private static Integer resolveModeId(Object configs, float rate,
                                         int width, int height) {
        try {
            Object value = Reflect.getField(configs, "mSupportedModes");
            if (!(value instanceof SparseArray<?>)) {
                return null;
            }
            SparseArray<?> modes = (SparseArray<?>) value;

            Integer exact = null;
            Integer exactAnyGeometry = null;
            Integer closest = null;
            float closestDelta = Float.MAX_VALUE;
            for (int index = 0; index < modes.size(); index++) {
                int modeId = modes.keyAt(index);
                Object displayMode = displayMode(modes.valueAt(index));
                if (displayMode == null) {
                    continue;
                }
                int modeWidth = intField(displayMode, "width");
                int modeHeight = intField(displayMode, "height");
                float modeRate = refreshRate(displayMode);
                if (modeRate <= 0.0f) {
                    continue;
                }
                if (Math.abs(modeRate - rate) <= RATE_EPSILON_HZ) {
                    if (modeWidth == width && modeHeight == height) {
                        if (exact == null || modeId < exact) {
                            exact = modeId;
                        }
                    } else if (exactAnyGeometry == null
                            || modeId < exactAnyGeometry) {
                        exactAnyGeometry = modeId;
                    }
                    continue;
                }
                if (modeWidth == width && modeHeight == height) {
                    float delta = Math.abs(modeRate - rate);
                    if (delta < closestDelta) {
                        closestDelta = delta;
                        closest = modeId;
                    }
                }
            }
            if (exact != null) {
                return exact;
            }
            Integer target = targetModeId(modes, width, height);
            if (target != null) {
                return target;
            }
            if (exactAnyGeometry != null) {
                return exactAnyGeometry;
            }
            return closest;
        } catch (Throwable ignored) {
            return null;
        }
    }

    /** The tier the daemon currently selected, matched by geometry. */
    private static Integer targetModeId(SparseArray<?> modes, int width, int height) {
        int[] target = readTarget();
        if (target == null || target[0] != width || target[1] != height) {
            return null;
        }
        Integer best = null;
        for (int index = 0; index < modes.size(); index++) {
            int modeId = modes.keyAt(index);
            Object displayMode = displayMode(modes.valueAt(index));
            if (displayMode == null
                    || intField(displayMode, "width") != width
                    || intField(displayMode, "height") != height) {
                continue;
            }
            if (Math.abs(refreshRate(displayMode) - target[2]) <= RATE_EPSILON_HZ
                    && (best == null || modeId < best)) {
                best = modeId;
            }
        }
        return best;
    }

    private static int[] readTarget() {
        try (java.io.BufferedReader reader = new java.io.BufferedReader(
                new java.io.FileReader(TARGET_FILE))) {
            String line;
            while ((line = reader.readLine()) != null) {
                String trimmed = line.trim();
                if (trimmed.isEmpty() || trimmed.startsWith("#")) {
                    continue;
                }
                String[] parts = trimmed.split("\\s+");
                String geometry = parts[0];
                if (parts.length >= 3 && !geometry.contains("x")) {
                    geometry = parts[1];
                    parts = new String[]{parts[1], parts[2]};
                }
                int separator = geometry.indexOf('x');
                if (separator <= 0 || parts.length < 2) {
                    continue;
                }
                int width = Integer.parseInt(geometry.substring(0, separator));
                int height = Integer.parseInt(geometry.substring(separator + 1));
                int fps = (int) Math.round(Double.parseDouble(parts[1]));
                return new int[]{width, height, fps};
            }
        } catch (Throwable ignored) {
            // A missing or unreadable file only disables the target fallback.
        }
        return null;
    }

    private static Object displayMode(Object record) {
        try {
            return Reflect.getField(record, "mode");
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static float refreshRate(Object displayMode) {
        float rate = floatField(displayMode, "peakRefreshRate");
        if (rate > 0.0f) {
            return rate;
        }
        return floatField(displayMode, "vsyncRate");
    }

    private static int intField(Object owner, String name) {
        Object value = field(owner, name);
        return value instanceof Number ? ((Number) value).intValue() : -1;
    }

    private static float floatField(Object owner, String name) {
        Object value = field(owner, name);
        return value instanceof Number ? ((Number) value).floatValue() : -1.0f;
    }

    private static Object field(Object owner, String name) {
        try {
            return Reflect.getField(owner, name);
        } catch (Throwable ignored) {
            return null;
        }
    }
}