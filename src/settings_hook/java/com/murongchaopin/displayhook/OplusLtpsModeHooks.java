package com.murongchaopin.displayhook;

import android.util.SparseArray;
import android.view.Display;

import java.lang.reflect.Method;

/** Keeps ColorOS' QHD low-rate vote attached to the native QHD60 timing. */
final class OplusLtpsModeHooks {
    private static final String REFRESH_RATE_CORE =
            "com.android.server.wm.OplusRefreshRateCore";
    private static final int QHD_WIDTH = 1440;
    private static final int QHD_HEIGHT = 3136;
    private static final int MAX_PRIORITY = 150;
    private static final float LTPS_RATE_HZ = 60.0f;
    private static final float RATE_EPSILON_HZ = 1.0f;

    private static String lastDecision = "";

    private OplusLtpsModeHooks() {
    }

    static int install(DisplaySettingsHook module, ClassLoader loader) {
        String model = systemProperty("ro.product.vendor.model", "");
        if (!"RMX5200".equalsIgnoreCase(model)) {
            module.info("QHD LTPS mode hook skipped model=" + model);
            return 0;
        }

        try {
            Class<?> owner = Class.forName(REFRESH_RATE_CORE, false, loader);
            int installed = 0;
            for (Method method : owner.getDeclaredMethods()) {
                Class<?>[] parameters = method.getParameterTypes();
                if (!"getFinalDisplayModeIdLocked".equals(method.getName())
                        || method.getReturnType() != int.class
                        || parameters.length != 5
                        || !SparseArray.class.isAssignableFrom(parameters[0])
                        || !"android.view.DisplayInfo".equals(parameters[1].getName())
                        || parameters[2] != int.class
                        || parameters[3] != int.class
                        || parameters[4] != boolean.class) {
                    continue;
                }
                method.setAccessible(true);
                module.intercept(method, "oplus.ltps.qhd-final-mode", chain -> {
                    Object original = chain.proceed();
                    return correctQhdLtpsMode(module, chain.getThisObject(),
                            chain.getArg(0), chain.getArg(1),
                            ((Number) chain.getArg(2)).intValue(),
                            ((Number) chain.getArg(3)).intValue(),
                            Boolean.TRUE.equals(chain.getArg(4)), original);
                });
                installed++;
            }
            if (installed != 1) {
                throw new NoSuchMethodException("QHD LTPS hook expected=1 actual="
                        + installed);
            }
            module.info("QHD LTPS mode hook installed=" + installed
                    + " model=" + model + " target=" + QHD_WIDTH + "x"
                    + QHD_HEIGHT + "@" + LTPS_RATE_HZ);
            return installed;
        } catch (Throwable error) {
            module.error("QHD LTPS mode hook unavailable", error);
            return 0;
        }
    }

    private static Object correctQhdLtpsMode(DisplaySettingsHook module, Object core,
                                             Object votes, Object displayInfo,
                                             int width, int height, boolean topOnly,
                                             Object original) {
        if (width != QHD_WIDTH || height != QHD_HEIGHT
                || !(votes instanceof SparseArray<?>) || displayInfo == null) {
            return original;
        }
        try {
            Object requestedValue = Reflect.call(core, "getPerfectRefreshRate",
                    votes, MAX_PRIORITY, topOnly);
            if (!(requestedValue instanceof Number)) {
                return original;
            }
            float requested = ((Number) requestedValue).floatValue();
            if (Math.abs(requested - LTPS_RATE_HZ) > RATE_EPSILON_HZ) {
                return original;
            }

            Object modesValue = Reflect.getField(displayInfo, "supportedModes");
            if (!(modesValue instanceof Display.Mode[])) {
                return original;
            }
            Display.Mode selected = findExactMode((Display.Mode[]) modesValue,
                    width, height, LTPS_RATE_HZ);
            if (selected == null) {
                module.info("QHD LTPS request has no exact mode request=" + requested);
                return original;
            }

            int originalId = original instanceof Number
                    ? ((Number) original).intValue() : -1;
            int selectedId = selected.getModeId();
            String decision = "request=" + requested + " original=" + originalId
                    + " selected=" + selectedId + " topOnly=" + topOnly;
            synchronized (OplusLtpsModeHooks.class) {
                if (!decision.equals(lastDecision)) {
                    lastDecision = decision;
                    module.info((originalId == selectedId
                            ? "QHD LTPS mode confirmed "
                            : "QHD LTPS mode corrected ") + decision);
                }
            }
            return selectedId;
        } catch (Throwable error) {
            module.error("QHD LTPS mode correction failed", error);
            return original;
        }
    }

    private static Display.Mode findExactMode(Display.Mode[] modes, int width,
                                              int height, float refreshRate) {
        Display.Mode selected = null;
        for (Display.Mode mode : modes) {
            if (mode == null
                    || mode.getPhysicalWidth() != width
                    || mode.getPhysicalHeight() != height
                    || Math.abs(mode.getRefreshRate() - refreshRate)
                    > RATE_EPSILON_HZ) {
                continue;
            }
            if (selected == null || mode.getModeId() < selected.getModeId()) {
                selected = mode;
            }
        }
        return selected;
    }

    private static String systemProperty(String key, String fallback) {
        try {
            Class<?> properties = Class.forName("android.os.SystemProperties");
            Method get = properties.getDeclaredMethod("get", String.class, String.class);
            get.setAccessible(true);
            Object value = get.invoke(null, key, fallback);
            return value instanceof String ? (String) value : fallback;
        } catch (Throwable ignored) {
            return fallback;
        }
    }
}
