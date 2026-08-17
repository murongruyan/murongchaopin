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
    private static final String RESOLUTION =
            "com.android.server.wm.OplusResolutionSwitchImpl";
    private static final String FRTC_KEY = "murong-display-hook-version-1";

    private static final Map<String, Integer> RATE_CACHE = new ConcurrentHashMap<>();
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "MurongOplusServices");
        thread.setDaemon(true);
        return thread;
    });
    private static String activePackage = "";

    private OplusServicesHooks() {
    }

    static int install(DisplaySettingsHook module, ClassLoader loader) {
        int modeResolver = FrameworkModeResolverHooks.install(module, loader);
        int resolutionVotes = FrameworkResolutionVoteHooks.install(module, loader);
        int ltpsMode = OplusLtpsModeHooks.install(module, loader);
        int physicalEnvelope = FrameworkPhysicalEnvelopeHooks.install(module, loader);
        int animationVotes = hookObjectAnimationVotes(module, loader);
        int preferred = hook(module, loader, SERVICE, "getPreferredFrameRate", 2,
                "services.preferred", chain -> {
                    Object packageValue = chain.getArg(0);
                    String packageName = packageValue instanceof String
                            ? (String) packageValue : "";
                    Integer fps = RATE_CACHE.get(packageName);
                    return fps != null && fps >= 30 ? fps.floatValue() : chain.proceed();
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
                    Object result = chain.proceed();
                    Object packageValue = chain.getArg(0);
                    Object rateValue = chain.getArg(2);
                    WORKER.execute(() -> synchronizeStockSelection(
                            module, packageValue, rateValue));
                    return result;
                });
        int remove = hook(module, loader, CONFIGS, "removeCustomizeRefreshRate", 1,
                "services.override.remove", chain -> {
                    Object result = chain.proceed();
                    if (!Boolean.FALSE.equals(result) && chain.getArg(0) instanceof String) {
                        String packageName = (String) chain.getArg(0);
                        RATE_CACHE.remove(packageName);
                        WORKER.execute(() -> BridgeClient.removeAppRate(packageName));
                    }
                    return result;
                });
        int clear = hook(module, loader, CONFIGS, "removeAllCustomizeRefreshRate", 0,
                "services.override.clear", chain -> {
                    Object result = chain.proceed();
                    if (!Boolean.FALSE.equals(result)) {
                        RATE_CACHE.clear();
                        WORKER.execute(BridgeClient::clearAppRates);
                    }
                    return result;
                });
        int resolution = hook(module, loader, RESOLUTION,
                "onResolutionSettingsChange", 1,
                "services.resolution.adopt", chain -> {
                    boolean firstInit = Boolean.TRUE.equals(chain.getArg(0));
                    Object result = chain.proceed();
                    module.info("Oplus resolution native-path=proceeded firstInit="
                            + firstInit);
                    return result;
                });
        module.info("Oplus services hooks installed modeResolver=" + modeResolver
                + " resolutionVotes=" + resolutionVotes
                + " ltpsMode=" + ltpsMode
                + " physicalEnvelope=" + physicalEnvelope
                + " animationVotes=" + animationVotes
                + " preferred=" + preferred
                + " front=" + front + " set=" + set + " remove=" + remove
                + " clear=" + clear + " resolution=" + resolution);
        return modeResolver + resolutionVotes + ltpsMode + physicalEnvelope + animationVotes
                + preferred + front + set + remove + clear + resolution;
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
                        module.info("Suppressed Oplus object-animation vote fps=" + fps
                                + " package=" + packageName
                                + " description=" + description);
                        return Boolean.TRUE;
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

    private static boolean isObjectAnimationVote(String packageName,
                                                 String description) {
        return packageName.contains("object-animation")
                || description.contains("object-animation");
    }

    private static String stringValue(Object value) {
        return value instanceof String ? (String) value : "";
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
                module.intercept(method, id, interceptor::invoke);
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
                module.info("Oplus services applied " + packageName + "=" + fps + "Hz");
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
        if (fps > 0 && BridgeClient.setAppRate(packageName, fps)) {
            RATE_CACHE.put(packageName, fps);
            module.info("Oplus services stored " + packageName + "=" + fps + "Hz");
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

    private interface Call {
        Object invoke(io.github.libxposed.api.XposedInterface.Chain chain) throws Throwable;
    }
}
