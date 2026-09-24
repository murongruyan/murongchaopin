package com.murongchaopin.displayhook;

import java.lang.reflect.Method;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Keeps ColorOS' system_server refresh policy synchronized with exact FPS overrides. */
final class OplusServicesHooks {
    private static final String SERVICE = "com.oplus.vrr.OPlusRefreshRateService";
    private static final String EXTERNAL_MANAGER =
            "com.oplus.vrr.OPlusExternalRefreshRateManager";
    private static final String CONFIGS = "com.android.server.wm.OplusRefreshRateConfigs";
    private static final String FRTC_KEY = "murong-display-hook-version-1";

    private static final Map<String, Integer> RATE_CACHE = new ConcurrentHashMap<>();
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "MurongOplusServices");
        thread.setDaemon(true);
        return thread;
    });
    private static final ThreadLocal<Class<?>> CURRENT_RETURN_TYPE = new ThreadLocal<>();
    private static String activePackage = "";

    private OplusServicesHooks() {
    }

    static int install(DisplaySettingsHook module, ClassLoader loader) {
        int modeResolver = FrameworkModeResolverHooks.install(module, loader);
        int resolutionVotes = FrameworkResolutionVoteHooks.install(module, loader);
        int ltpsMode = OplusLtpsModeHooks.install(module, loader);
        int physicalEnvelope = FrameworkPhysicalEnvelopeHooks.install(module, loader);
        int animationVotes = hookObjectAnimationVotes(module, loader);
        int vrrTier = OplusVrrTierHooks.install(module, loader);
        int vrrPolicy = OplusVrrTierHooks.installPolicyHooks(module, loader);
        int modeEvent = OplusVrrTierHooks.installEventHooks(module, loader);
        int activeMode = OplusVrrTierHooks.installActiveModeHooks(module, loader);
        int appRequest = OplusVrrTierHooks.installAppRequestHooks(module, loader);
        int preferred = hook(module, loader, SERVICE, "getPreferredFrameRate", 2,
                "services.preferred", chain -> {
                    Object packageValue = chain.getArg(0);
                    String packageName = packageValue instanceof String
                            ? (String) packageValue : "";
                    Integer fps = RATE_CACHE.get(packageName);
                    if (fps != null && fps >= 30) {
                        return fps.floatValue();
                    }
                    Object original = chain.proceed();
                    logProbe(module, "getPreferredFrameRate", packageName, original);
                    /* ColourOS clamps every app to its refresh tier, and the
                     * ColourOS 17 tier enum cannot express an overclock target,
                     * so an app never sees the rate the user selected.  The
                     * module global mode.txt entry is that selection, so hand it
                     * back when the vendor answer is lower. */
                    int global = globalRate();
                    if (global >= 30 && original instanceof Number
                            && ((Number) original).floatValue() < (float) global) {
                        logPreferredOverride(module, packageName, original, global);
                        return (float) global;
                    }
                    return original;
                });
        int front = hook(module, loader, SERVICE, "handleFrontAppChange", 1,
                "services.front", chain -> {
                    Object result = chain.proceed();
                    Object service = chain.getThisObject();
                    Object packageValue = chain.getArg(0);
                    WORKER.execute(() -> synchronizeFrontApp(module, service, packageValue));
                    return result;
                });
        int set = hook(module, loader, CONFIGS, "setUsrOverrideRefreshRate", 3,
                "services.override.set", chain -> {
                    Object packageValue = chain.getArg(0);
                    Object rateValue = chain.getArg(2);
                    WORKER.execute(() -> synchronizeStockSelection(
                            module, packageValue, rateValue));
                    // Keep mode.txt as the only durable per-app override. Letting
                    // OplusRefreshRateConfigs proceed here creates a second store
                    // that Settings can later read back instead of the daemon.
                    return interceptedSuccess(methodReturnType(chain));
                });
        int remove = hook(module, loader, CONFIGS, "removeCustomizeRefreshRate", 1,
                "services.override.remove", chain -> {
                    if (chain.getArg(0) instanceof String) {
                        String packageName = (String) chain.getArg(0);
                        RATE_CACHE.remove(packageName);
                        WORKER.execute(() -> BridgeClient.removeAppRate(packageName));
                    }
                    return interceptedSuccess(methodReturnType(chain));
                });
        int clear = hook(module, loader, CONFIGS, "removeAllCustomizeRefreshRate", 0,
                "services.override.clear", chain -> {
                    RATE_CACHE.clear();
                    WORKER.execute(BridgeClient::clearAppRates);
                    return interceptedSuccess(methodReturnType(chain));
                });
        module.info("Oplus services hooks installed modeResolver=" + modeResolver
                + " resolutionVotes=" + resolutionVotes
                + " ltpsMode=" + ltpsMode
                + " physicalEnvelope=" + physicalEnvelope
                + " animationVotes=" + animationVotes + " vrrTier=" + vrrTier + " vrrPolicy=" + vrrPolicy + " modeEvent=" + modeEvent + " activeMode=" + activeMode + " appRequest=" + appRequest
                + " preferred=" + preferred
                + " front=" + front + " set=" + set + " remove=" + remove
                + " clear=" + clear);
        return modeResolver + resolutionVotes + ltpsMode + physicalEnvelope + animationVotes + vrrTier + vrrPolicy + modeEvent + activeMode + appRequest
                + preferred + front + set + remove + clear;
    }

    private static int hookObjectAnimationVotes(DisplaySettingsHook module,
                                                ClassLoader loader) {
        int count = 0;
        try {
            Class<?> owner = Class.forName(EXTERNAL_MANAGER, false, loader);
            for (Method method : owner.getDeclaredMethods()) {
                Class<?>[] parameters = method.getParameterTypes();
                if (!"addFRTCFrameRate".equals(method.getName())
                        || method.getReturnType() != boolean.class
                        || parameters.length != 6
                        || parameters[0] != int.class
                        || parameters[1] != String.class
                        || parameters[2] != boolean.class
                        || parameters[3] != String.class
                        || parameters[4] != int.class
                        || parameters[5] != int.class) {
                    continue;
                }
                method.setAccessible(true);
                final String id = "services.animation-vote." + count++;
                module.intercept(method, id, chain -> {
                    int fps = ((Number) chain.getArg(0)).intValue();
                    String packageName = stringValue(chain.getArg(1));
                    String description = stringValue(chain.getArg(3));
                    if (fps > 0 && isObjectAnimationVote(packageName, description)) {
                        return Boolean.TRUE;
                    }
                    /* ColourOS pins every app to its refresh tier through this
                     * frame-rate target control.  The ColourOS 17 tier enum stops at
                     * 144, so an app can never reach the overclock target the user
                     * selected even though the panel runs there.  High-rate caps
                     * (>=120) are that tier ceiling rather than a content decision,
                     * so re-issue them with the module selection; low caps (video,
                     * idle) are left untouched. */
                    logProbe(module, "addFRTCFrameRate", packageName + "/" + description, Integer.valueOf(fps));
                    int target = globalRate();
                    if (fps >= 120 && target > fps) {
                        logFrtcLift(module, packageName, description, fps, target);
                        return reissueFrtc(chain, target);
                    }
                    // A zero-rate call removes an existing vote and must always reach
                    // SurfaceFlinger, including after a hook reload.
                    return chain.proceed();
                });
            }
        } catch (Throwable error) {
            module.error("Oplus object-animation vote hook unavailable", error);
        }
        return count;
    }

    private static final java.util.Set<String> FRTC_LOGGED =
            java.util.Collections.newSetFromMap(new ConcurrentHashMap<>());
    private static final ThreadLocal<Boolean> FRTC_REENTRY =
            ThreadLocal.withInitial(() -> Boolean.FALSE);

    private static final java.util.Set<String> PROBE_LOGGED =
            java.util.Collections.newSetFromMap(new ConcurrentHashMap<>());

    /** Temporary instrumentation: record every vendor frame-rate answer. */
    private static void logProbe(DisplaySettingsHook module, String source,
                                 String key, Object value) {
        String tag = source + " " + key + " = " + value;
        if (PROBE_LOGGED.size() > 60 || !PROBE_LOGGED.add(tag)) {
            return;
        }
        module.info("probe " + tag);
    }

    private static void logFrtcLift(DisplaySettingsHook module, String packageName,
                                    String description, int fps, int target) {
        String key = packageName + "|" + fps;
        if (FRTC_LOGGED.size() > 40 || !FRTC_LOGGED.add(key)) {
            return;
        }
        module.info("Frame rate cap lifted for " + packageName + " (" + description
                + "): vendor=" + fps + " -> module=" + target);
    }

    /** Re-issue the vendor frame-rate target with the module rate, guarded so the
     *  re-entrant hook call passes straight through. */
    private static Object reissueFrtc(io.github.libxposed.api.XposedInterface.Chain chain,
                                      int fps) throws Throwable {
        if (Boolean.TRUE.equals(FRTC_REENTRY.get())) {
            return chain.proceed();
        }
        FRTC_REENTRY.set(Boolean.TRUE);
        try {
            Object owner = chain.getThisObject();
            Reflect.call(owner, "addFRTCFrameRate", Integer.valueOf(fps), chain.getArg(1),
                    chain.getArg(2), chain.getArg(3), chain.getArg(4), chain.getArg(5));
            return Boolean.TRUE;
        } catch (Throwable error) {
            return chain.proceed();
        } finally {
            FRTC_REENTRY.remove();
        }
    }

    private static boolean isObjectAnimationVote(String packageName,
                                                 String description) {
        return packageName.contains("object-animation")
                || description.contains("object-animation");
    }

    private static String stringValue(Object value) {
        return value instanceof String ? (String) value : "";
    }

    private static volatile int globalRateCache;
    private static volatile long globalRateCachedAt;
    private static final java.util.Set<String> PREFERRED_LOGGED =
            java.util.Collections.newSetFromMap(new ConcurrentHashMap<>());

    private static int globalRate() {
        long now = android.os.SystemClock.elapsedRealtime();
        if (now - globalRateCachedAt < 5000L && globalRateCache > 0) {
            return globalRateCache;
        }
        int value = BridgeClient.globalRate();
        if (value >= 30) {
            globalRateCache = value;
            globalRateCachedAt = now;
        }
        return value;
    }

    private static void logPreferredOverride(DisplaySettingsHook module, String packageName,
                                             Object original, int global) {
        if (packageName.isEmpty() || PREFERRED_LOGGED.size() > 40
                || !PREFERRED_LOGGED.add(packageName)) {
            return;
        }
        module.info("Preferred frame rate lifted for " + packageName + ": vendor="
                + original + " -> module=" + global);
    }
    private static int hook(DisplaySettingsHook module, ClassLoader loader,
                            String className, String methodName, int parameterCount,
                            String idPrefix, Call interceptor) {
        int count = 0;
        try {
            Class<?> owner = Class.forName(className, false, loader);
            for (Method method : owner.getDeclaredMethods()) {
                if (!methodName.equals(method.getName())
                        || method.getParameterCount() != parameterCount) {
                    continue;
                }
                method.setAccessible(true);
                final String id = idPrefix + "." + count++;
                module.intercept(method, id, chain -> {
                    CURRENT_RETURN_TYPE.set(method.getReturnType());
                    try {
                        return interceptor.invoke(chain);
                    } finally {
                        CURRENT_RETURN_TYPE.remove();
                    }
                });
            }
        } catch (Throwable error) {
            module.error("Oplus service hook unavailable: " + className + "."
                    + methodName, error);
        }
        return count;
    }

    private static synchronized void synchronizeFrontApp(DisplaySettingsHook module,
                                                          Object service,
                                                          Object packageValue) {
        String packageName = packageValue instanceof String ? (String) packageValue : "";
        try {
            if (BridgeClient.validPackage(activePackage)
                    && !activePackage.equals(packageName)) {
                Reflect.call(service, "setFrameRateTargetControlAsynchronous",
                        0.0f, activePackage, true, FRTC_KEY);
            }
            int fps = BridgeClient.appRate(packageName);
            if (fps >= 30) {
                RATE_CACHE.put(packageName, fps);
                Reflect.call(service, "setFrameRateTargetControlAsynchronous",
                        (float) fps, packageName, true, FRTC_KEY);
                activePackage = packageName;
            } else {
                RATE_CACHE.remove(packageName);
                activePackage = "";
            }
        } catch (Throwable error) {
            module.error("Oplus services front-app synchronization failed", error);
        }
    }

    private static void synchronizeStockSelection(DisplaySettingsHook module,
                                                  Object packageValue,
                                                  Object rateValue) {
        if (!(packageValue instanceof String) || !(rateValue instanceof Number)) {
            return;
        }
        String packageName = (String) packageValue;
        int fps = fpsForRateId(((Number) rateValue).intValue());
        BridgeClient.ModeState global = BridgeClient.globalMode();
        if (fps > 0 && global.isValid() && BridgeClient.setAppMode(packageName,
                global.width, global.height, fps)) {
            RATE_CACHE.put(packageName, fps);
        }
    }

    private static int fpsForRateId(int rateId) {
        // The stock Settings popup sends ColorOS enum IDs, while the expanded
        // main/search popups send the exact physical FPS through the same API.
        if (rateId >= 30 && rateId <= 1000) {
            return rateId;
        }
        switch (rateId) {
            case 1: return 90;
            case 2: return 60;
            case 3: return 120;
            case 4: return 144;
            case 7: return 165;
            default: return -1;
        }
    }

    private static Class<?> methodReturnType(
            io.github.libxposed.api.XposedInterface.Chain chain) {
        try {
            Class<?> returnType = CURRENT_RETURN_TYPE.get();
            if (returnType != null) {
                return returnType;
            }
        } catch (Throwable ignored) {
            return boolean.class;
        }
        return boolean.class;
    }

    private static Object interceptedSuccess(Class<?> returnType) {
        if (returnType == void.class) return null;
        if (returnType == boolean.class || returnType == Boolean.class) return Boolean.TRUE;
        if (returnType == long.class || returnType == Long.class) return Long.valueOf(0L);
        if (returnType == float.class || returnType == Float.class) return Float.valueOf(0f);
        if (returnType == double.class || returnType == Double.class) return Double.valueOf(0d);
        if (returnType == short.class || returnType == Short.class) return Short.valueOf((short) 0);
        if (returnType == byte.class || returnType == Byte.class) return Byte.valueOf((byte) 0);
        if (returnType == int.class || returnType == Integer.class) return Integer.valueOf(0);
        return null;
    }

    private interface Call {
        Object invoke(io.github.libxposed.api.XposedInterface.Chain chain) throws Throwable;
    }
}
